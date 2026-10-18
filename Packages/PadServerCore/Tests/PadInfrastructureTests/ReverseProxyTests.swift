import Foundation
import HTTPTypes
import Hummingbird
import NIOConcurrencyHelpers
import NIOCore
@testable import PadInfrastructure
import Testing

private enum ReverseProxyTestConstants {
    static let kibibyte = 1_024
    static let chunkKibibytes = 64
    static let chunkSize = chunkKibibytes * kibibyte
    static let slowConsumerChunkCount = 16_384
    static let pollMilliseconds = 100
    static let maximumPolls = 100
    static let stablePollsRequired = 3
    static let readAheadLimitDivisor = 4
    static let readAheadLimit = slowConsumerChunkCount * chunkSize / readAheadLimitDivisor
    static let shortTimeoutMilliseconds = 200
    static let hangSeconds = 30
    static let uploadChunkCount = 8
    static let fillByte: UInt8 = 0x61
    static let echoLimit = 1_024
    static let unusedPort: UInt16 = 1
}

private typealias UpstreamHandler = @Sendable (Request) async throws -> Response

private func withUpstream<Result: Sendable>(
    handler: @escaping UpstreamHandler,
    _ body: @Sendable (UInt16) async throws -> Result
) async throws -> Result {
    let (ports, continuation) = AsyncStream<UInt16>.makeStream()
    let application = Application(
        responder: CallbackResponder<BasicRequestContext> { request, _ in try await handler(request) },
        configuration: .init(address: .hostname("127.0.0.1", port: 0)),
        onServerRunning: { channel in
            if let port = channel.localAddress?.port {
                continuation.yield(UInt16(port))
            }
        }
    )
    return try await withThrowingTaskGroup(of: Result?.self) { group in
        group.addTask {
            try await application.runService()
            return nil
        }
        var iterator = ports.makeAsyncIterator()
        guard let port = await iterator.next() else {
            throw CancellationError()
        }
        let result = try await body(port)
        group.cancelAll()
        _ = try await group.next()
        return result
    }
}

private func filledChunk() -> ByteBuffer {
    ByteBuffer(repeating: ReverseProxyTestConstants.fillByte, count: ReverseProxyTestConstants.chunkSize)
}

private func fieldName(_ raw: String) throws -> HTTPField.Name {
    try #require(HTTPField.Name(raw))
}

private func proxyRequest(
    method: HTTPRequest.Method = .get, path: String = "/", headers: HTTPFields = [:], body: ByteBuffer? = nil
) -> Request {
    var fields = headers
    if let body, fields[.contentLength] == nil, fields[.transferEncoding] == nil {
        fields[.contentLength] = String(body.readableBytes)
    }
    let head = HTTPRequest(
        method: method, scheme: "http", authority: "app.example.com", path: path, headerFields: fields)
    return Request(head: head, body: RequestBody(buffer: body ?? ByteBuffer()))
}

private struct ProbeWriter: ResponseBodyWriter {
    let onWrite: @Sendable (ByteBuffer) async throws -> Void
    let onFinish: @Sendable () async -> Void

    mutating func write(_ buffer: ByteBuffer) async throws {
        try await onWrite(buffer)
    }

    consuming func finish(_ trailingHeaders: HTTPFields?) async throws {
        await onFinish()
    }
}

private func collect(_ response: Response) async throws -> ByteBuffer {
    let collected = NIOLockedValueBox(ByteBuffer())
    let finished = NIOLockedValueBox(false)
    let writer = ProbeWriter(
        onWrite: { chunk in
            _ = collected.withLockedValue { $0.writeImmutableBuffer(chunk) }
            await Task.yield()
        },
        onFinish: { finished.withLockedValue { $0 = true } }
    )
    try await response.body.write(writer)
    #expect(finished.withLockedValue { $0 })
    return collected.withLockedValue { $0 }
}

private func echoHandler(
    seen: NIOLockedValueBox<HTTPRequest?>, seenBody: NIOLockedValueBox<String>
) -> UpstreamHandler {
    { request in
        seen.withLockedValue { $0 = request.head }
        let body = try await request.body.collect(upTo: ReverseProxyTestConstants.echoLimit)
        seenBody.withLockedValue { $0 = String(buffer: body) }
        return Response(status: .created, headers: [.contentType: "text/plain"], body: .init(byteBuffer: body))
    }
}

// 量が連続して変わらなくなるか, 上限を超えた時点の量を返す。どちらにもならなければ Int.max を返す。
private func settledValue(of box: NIOLockedValueBox<Int>, limit: Int) async throws -> Int {
    var previous = box.withLockedValue { $0 }
    var stablePolls = 0
    for _ in 0..<ReverseProxyTestConstants.maximumPolls {
        try await Task.sleep(for: .milliseconds(ReverseProxyTestConstants.pollMilliseconds))
        let current = box.withLockedValue { $0 }
        if current > limit { return current }
        stablePolls = current == previous ? stablePolls + 1 : 0
        if stablePolls >= ReverseProxyTestConstants.stablePollsRequired { return current }
        previous = current
    }
    return Int.max
}

private func slowConsumerHandler(produced: NIOLockedValueBox<Int>) -> UpstreamHandler {
    { _ in
        let chunk = filledChunk()
        let body = ResponseBody { writer in
            for _ in 0..<ReverseProxyTestConstants.slowConsumerChunkCount {
                try await writer.write(chunk)
                produced.withLockedValue { $0 += chunk.readableBytes }
            }
            try await writer.finish(nil)
        }
        return Response(status: .ok, body: body)
    }
}

@Test func reverseProxyForwardsRequestWithForwardingHeaders() async throws {
    let hop = try fieldName("X-Hop")
    let forwardedHost = try fieldName("X-Forwarded-Host")
    let forwardedProto = try fieldName("X-Forwarded-Proto")
    let seen = NIOLockedValueBox<HTTPRequest?>(nil)
    let seenBody = NIOLockedValueBox("")
    try await withUpstream(handler: echoHandler(seen: seen, seenBody: seenBody)) { port in
        var headers = HTTPFields()
        headers[.contentType] = "text/plain"
        headers[.connection] = "keep-alive, X-Hop"
        headers[hop] = "secret"
        headers[forwardedHost] = "spoofed.example.org"
        let request = proxyRequest(
            method: .post, path: "/api/items?id=7", headers: headers, body: ByteBuffer(string: "payload"))
        let response = try await ReverseProxy().forward(request, to: port)

        #expect(response.status == .created)
        #expect(response.headers[.contentType] == "text/plain")
        #expect(String(buffer: try await collect(response)) == "payload")
    }
    let head = try #require(seen.withLockedValue { $0 })
    #expect(head.method == .post)
    #expect(head.path == "/api/items?id=7")
    #expect(head.authority == "app.example.com")
    #expect(head.headerFields[forwardedHost] == "app.example.com")
    #expect(head.headerFields[forwardedProto] == "https")
    #expect(head.headerFields[hop] == nil)
    #expect(seenBody.withLockedValue { $0 } == "payload")
}

@Test func reverseProxyStreamsChunkedRequestBodyWithoutLength() async throws {
    let received = NIOLockedValueBox(0)
    let handler: UpstreamHandler = { request in
        var total = 0
        for try await chunk in request.body {
            total += chunk.readableBytes
        }
        received.withLockedValue { $0 = total }
        return Response(status: .noContent)
    }
    try await withUpstream(handler: handler) { port in
        let piece = filledChunk()
        let pieces = Array(repeating: piece, count: ReverseProxyTestConstants.uploadChunkCount)
        let body = RequestBody(
            asyncSequence: AsyncStream<ByteBuffer> { continuation in
                pieces.forEach { continuation.yield($0) }
                continuation.finish()
            })
        let head = HTTPRequest(
            method: .put, scheme: "http", authority: "app.example.com", path: "/upload",
            headerFields: [.transferEncoding: "chunked"])
        let response = try await ReverseProxy().forward(Request(head: head, body: body), to: port)

        #expect(response.status == .noContent)
    }
    let expected = ReverseProxyTestConstants.uploadChunkCount * ReverseProxyTestConstants.chunkSize
    #expect(received.withLockedValue { $0 } == expected)
}

@Test func reverseProxyPassesThroughErrorStatusAndDropsHopByHopResponseHeaders() async throws {
    let handler: UpstreamHandler = { _ in
        Response(
            status: .notFound,
            headers: [.contentType: "text/plain", .proxyAuthenticate: "Basic"],
            body: .init(byteBuffer: ByteBuffer(string: "missing"))
        )
    }
    try await withUpstream(handler: handler) { port in
        let response = try await ReverseProxy().forward(proxyRequest(path: "/nope"), to: port)

        #expect(response.status == .notFound)
        #expect(response.headers[.contentLength] == "7")
        #expect(response.headers[.transferEncoding] == nil)
        #expect(response.headers[.proxyAuthenticate] == nil)
        #expect(String(buffer: try await collect(response)) == "missing")
    }
}

@Test func reverseProxyReturnsBadGatewayWhenNothingListens() async throws {
    let response = try await ReverseProxy().forward(proxyRequest(), to: ReverseProxyTestConstants.unusedPort)

    #expect(response.status == .badGateway)
}

@Test func reverseProxyReturnsGatewayTimeoutWhenHeadNeverArrives() async throws {
    let handler: UpstreamHandler = { _ in
        try await Task.sleep(for: .seconds(ReverseProxyTestConstants.hangSeconds))
        return Response(status: .ok)
    }
    try await withUpstream(handler: handler) { port in
        let timeout = Duration.milliseconds(ReverseProxyTestConstants.shortTimeoutMilliseconds)
        let response = try await ReverseProxy(responseHeadTimeout: timeout).forward(proxyRequest(), to: port)

        #expect(response.status == .gatewayTimeout)
    }
}

// 実装の先読みは 1 MiB 未満で有界。produced の大半は kernel の buffer で数十 MiB まで揺れるため、総量の 1/4 を上限にする。
@Test func reverseProxyDoesNotReadAheadWhenResponseIsConsumedSlowly() async throws {
    let produced = NIOLockedValueBox(0)
    let plateau = NIOLockedValueBox(0)
    let consumed = NIOLockedValueBox(0)
    let finished = NIOLockedValueBox(false)
    let totalBytes = ReverseProxyTestConstants.chunkSize * ReverseProxyTestConstants.slowConsumerChunkCount
    try await withUpstream(handler: slowConsumerHandler(produced: produced)) { port in
        let response = try await ReverseProxy().forward(proxyRequest(), to: port)
        let writer = ProbeWriter(
            onWrite: { chunk in
                if consumed.withLockedValue({ $0 == 0 }) {
                    let settled = try await settledValue(of: produced, limit: ReverseProxyTestConstants.readAheadLimit)
                    plateau.withLockedValue { $0 = settled }
                }
                consumed.withLockedValue { $0 += chunk.readableBytes }
            },
            onFinish: { finished.withLockedValue { $0 = true } }
        )
        try await response.body.write(writer)
    }
    #expect(finished.withLockedValue { $0 })
    #expect(consumed.withLockedValue { $0 } == totalBytes)
    #expect(plateau.withLockedValue { $0 } <= ReverseProxyTestConstants.readAheadLimit)
}
