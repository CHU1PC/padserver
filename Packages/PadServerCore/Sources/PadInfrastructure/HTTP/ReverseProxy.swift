import AsyncAlgorithms
import Foundation
import HTTPTypes
import Hummingbird
import NIOCore
import NIOHTTP1
import NIOHTTPTypes
import NIOHTTPTypesHTTP1
import NIOPosix

public struct ReverseProxy: Sendable {
    private enum ProxyError: Error {
        case responseHeadTimeout
        case noResponse
        case invalidHeaderName
    }

    // loopback への接続は即座に成立するため、5 秒で繋がらなければ guest 側の異常として扱う。
    private static let connectTimeoutSeconds: Int64 = 5
    // container が応答の head を返し始めるまでの上限。重い処理を待てるように 60 秒にする。
    private static let responseHeadTimeoutSeconds = 60
    // TLS は relay が終えるため、container から見た元の要求は常に https になる。
    private static let forwardedProto = "https"
    private static let hopByHopNames: Set<String> = [
        "connection", "keep-alive", "proxy-authenticate", "proxy-authorization", "proxy-connection", "te",
        "trailer", "transfer-encoding", "upgrade",
    ]

    private typealias UpstreamChannel = NIOAsyncChannel<HTTPResponsePart, HTTPRequestPart>

    private let responseHeadTimeout: Duration

    public init() {
        self.init(responseHeadTimeout: .seconds(Self.responseHeadTimeoutSeconds))
    }

    init(responseHeadTimeout: Duration) {
        self.responseHeadTimeout = responseHeadTimeout
    }

    /// loopback の `hostPort` へ要求を流して, 応答の本文を小分けのまま返す.
    /// 繋がらないときは 502, head が時間内に届かないときは 504 を返す.
    public func forward(_ request: Request, to hostPort: UInt16) async throws -> Response {
        let heads = AsyncThrowingChannel<HTTPResponse, any Error>()
        let chunks = AsyncThrowingChannel<ByteBuffer, any Error>()
        let upstream = try Self.upstreamRequest(from: request)
        let session = Task {
            await Self.exchange(upstream, body: request.body, with: hostPort, heads: heads, chunks: chunks)
        }

        let head: HTTPResponse
        do {
            head = try await Self.firstHead(of: heads, timeout: responseHeadTimeout)
        } catch is CancellationError {
            session.cancel()
            throw CancellationError()
        } catch ProxyError.responseHeadTimeout {
            session.cancel()
            return Response(status: .gatewayTimeout)
        } catch {
            // 接続の失敗も不正な応答も、呼び出し側には 502 として見せる。
            session.cancel()
            return Response(status: .badGateway)
        }

        return Response(
            status: head.status,
            headers: Self.withoutHopByHop(head.headerFields),
            body: ResponseBody { writer in
                defer { session.cancel() }
                for try await chunk in chunks {
                    try await writer.write(chunk)
                }
                try await writer.finish(nil)
            }
        )
    }

    private static func upstreamRequest(from request: Request) throws -> HTTPRequest {
        var fields = withoutHopByHop(request.headers, dropping: request.headers[values: .connection])
        let isChunked = request.headers[values: .transferEncoding].contains { $0.lowercased() == "chunked" }
        if isChunked && fields[.contentLength] == nil {
            fields[.transferEncoding] = "chunked"
        }
        fields[.connection] = "close"
        fields[try headerName("X-Forwarded-Host")] = request.head.authority
        fields[try headerName("X-Forwarded-Proto")] = forwardedProto
        return HTTPRequest(
            method: request.method, scheme: "http", authority: request.head.authority,
            path: request.head.path, headerFields: fields)
    }

    private static func headerName(_ raw: String) throws -> HTTPField.Name {
        guard let name = HTTPField.Name(raw) else { throw ProxyError.invalidHeaderName }
        return name
    }

    private static func withoutHopByHop(_ fields: HTTPFields, dropping extra: [String] = []) -> HTTPFields {
        let listed = extra.flatMap { $0.split(separator: ",") }
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        var result = HTTPFields()
        for field in fields {
            let name = field.name.canonicalName
            if !hopByHopNames.contains(name) && !listed.contains(name) {
                result.append(field)
            }
        }
        return result
    }

    private static func firstHead(
        of heads: AsyncThrowingChannel<HTTPResponse, any Error>, timeout: Duration
    ) async throws -> HTTPResponse {
        try await withThrowingTaskGroup(of: HTTPResponse?.self) { group in
            group.addTask {
                for try await head in heads {
                    return head
                }
                return nil
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw ProxyError.responseHeadTimeout
            }
            defer { group.cancelAll() }
            guard let result = try await group.next(), let head = result else {
                throw ProxyError.noResponse
            }
            return head
        }
    }

    private static func exchange(
        _ upstream: HTTPRequest, body: RequestBody, with hostPort: UInt16,
        heads: AsyncThrowingChannel<HTTPResponse, any Error>,
        chunks: AsyncThrowingChannel<ByteBuffer, any Error>
    ) async {
        do {
            let channel = try await connect(to: hostPort)
            try await channel.executeThenClose { inbound, outbound in
                try await send(upstream, body: body, to: outbound)
                try await relay(inbound, heads: heads, chunks: chunks)
            }
            heads.finish()
            chunks.finish()
        } catch {
            // 失敗の種類を問わず, head と本文の両方を待つ側へ同じ失敗を渡す。
            heads.fail(error)
            chunks.fail(error)
        }
    }

    private static func connect(to hostPort: UInt16) async throws -> UpstreamChannel {
        try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connectTimeout(.seconds(connectTimeoutSeconds))
            .connect(host: "127.0.0.1", port: Int(hostPort)) { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHTTPClientHandlers()
                    try channel.pipeline.syncOperations.addHandler(HTTP1ToHTTPClientCodec())
                    return try UpstreamChannel(wrappingChannelSynchronously: channel)
                }
            }
    }

    private static func send(
        _ upstream: HTTPRequest, body: RequestBody, to outbound: NIOAsyncChannelOutboundWriter<HTTPRequestPart>
    ) async throws {
        try await outbound.write(.head(upstream))
        // 長さも chunked も無い要求は本文を持たないので、読まずに終える。
        if upstream.headerFields[.contentLength] != nil || upstream.headerFields[.transferEncoding] != nil {
            for try await chunk in body {
                try await outbound.write(.body(chunk))
            }
        }
        try await outbound.write(.end(nil))
    }

    private static func relay(
        _ inbound: NIOAsyncChannelInboundStream<HTTPResponsePart>,
        heads: AsyncThrowingChannel<HTTPResponse, any Error>,
        chunks: AsyncThrowingChannel<ByteBuffer, any Error>
    ) async throws {
        for try await part in inbound {
            switch part {
            case .head(let head) where head.status.kind != .informational:
                await heads.send(head)

            case .head:
                continue

            case .body(let chunk):
                await chunks.send(chunk)

            case .end:
                return
            }
        }
    }
}
