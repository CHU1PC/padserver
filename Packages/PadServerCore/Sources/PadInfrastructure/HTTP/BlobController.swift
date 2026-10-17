import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct BlobController: Sendable {
    // 上限値は docs/admin-api.md の4.2で未決定。1 ファイルの配備に十分な 512 MiB とする。
    public static let defaultMaximumBytes: Int64 = 512 << 20

    private let storage: any ProjectStorage
    private let maximumBytes: Int64

    public init(storage: any ProjectStorage, maximumBytes: Int64 = BlobController.defaultMaximumBytes) {
        self.storage = storage
        self.maximumBytes = maximumBytes
    }

    public func addRoutes(to router: Router<AdminRequestContext>) {
        router.put("/v1/blobs/{hash}", use: upload)
    }

    private func upload(_ request: Request, context: AdminRequestContext) async throws -> Response {
        let hash: BlobHash
        do {
            hash = try BlobHash(context.parameters.get("hash") ?? "")
        } catch {
            return try errorResponse(.invalidRequest, message: "Blob hash is invalid.", status: .badRequest)
        }
        if try await storage.blobExists(hash) {
            return Response(status: .noContent)
        }
        if let declared = request.headers[.contentLength].flatMap(Int64.init), declared > maximumBytes {
            return try tooLargeResponse()
        }
        do {
            try await storage.saveBlob(hash, from: LimitedBodyStream(body: request.body, maximumBytes: maximumBytes))
        } catch is BodyTooLarge {
            return try tooLargeResponse()
        } catch FileBlobStore.Failure.hashMismatch {
            return try errorResponse(
                .invalidRequest, message: "Body does not match the blob hash.", status: .badRequest)
        }
        return Response(status: .created)
    }

    private func tooLargeResponse() throws -> Response {
        try errorResponse(.payloadTooLarge, message: "Request body is too large.", status: .contentTooLarge)
    }

    private func errorResponse(
        _ code: AdminErrorCode, message: String, status: HTTPResponse.Status
    ) throws -> Response {
        let body = AdminErrorResponse(error: AdminError(code: code, message: message))
        let data = try AdminAPIJSON.makeEncoder().encode(body)
        return Response(
            status: status, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }
}

private struct BodyTooLarge: Error {}

private struct LimitedBodyStream: HTTPBodyStream {
    struct Iterator: AsyncIteratorProtocol {
        var upstream: RequestBody.AsyncIterator
        var remaining: Int64

        mutating func next() async throws -> Data? {
            guard let buffer = try await upstream.next() else { return nil }
            remaining -= Int64(buffer.readableBytes)
            guard remaining >= 0 else { throw BodyTooLarge() }
            return Data(buffer.readableBytesView)
        }
    }

    let body: RequestBody
    let maximumBytes: Int64

    func makeAsyncIterator() -> Iterator {
        Iterator(upstream: body.makeAsyncIterator(), remaining: maximumBytes)
    }
}
