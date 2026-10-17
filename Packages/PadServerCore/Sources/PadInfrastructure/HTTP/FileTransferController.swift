import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct FileTransferController: Sendable {
    private let storeFile: StoreFile

    public init(storeFile: StoreFile) {
        self.storeFile = storeFile
    }

    public func addRoutes(to router: Router<AdminRequestContext>) {
        router.put("/v1/files/{name}", use: upload)
        router.get("/v1/files/{name}", use: download)
    }

    private func upload(_ request: Request, context: AdminRequestContext) async throws -> Response {
        let name = Self.decodedName(from: context)
        let stored: StoredFile
        do {
            stored = try await storeFile.save(named: name, from: RequestBodyStream(body: request.body))
        } catch StoreFile.Error.invalidName {
            return try errorResponse(.invalidRequest, message: "File name is invalid.", status: .badRequest)
        }
        let data = try AdminAPIJSON.makeEncoder().encode(stored)
        return Response(
            status: .created, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func download(_ request: Request, context: AdminRequestContext) async throws -> Response {
        let name = Self.decodedName(from: context)
        let stream: BlobBodyStream?
        do {
            stream = try await storeFile.open(named: name)
        } catch StoreFile.Error.invalidName {
            return try errorResponse(.invalidRequest, message: "File name is invalid.", status: .badRequest)
        }
        guard let stream else {
            return try errorResponse(.fileNotFound, message: "File was not found.", status: .notFound)
        }
        return Response(
            status: .ok, headers: [.contentType: "application/octet-stream"],
            body: ResponseBody { writer in
                for try await chunk in stream {
                    try await writer.write(ByteBuffer(bytes: chunk))
                }
                try await writer.finish(nil)
            })
    }

    // router は path parameter を percent-decode しないので、ここで戻す。
    private static func decodedName(from context: AdminRequestContext) -> String {
        (context.parameters.get("name") ?? "").removingPercentEncoding ?? ""
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

private struct RequestBodyStream: HTTPBodyStream {
    struct Iterator: AsyncIteratorProtocol {
        var upstream: RequestBody.AsyncIterator

        mutating func next() async throws -> Data? {
            guard let buffer = try await upstream.next() else { return nil }
            return Data(buffer.readableBytesView)
        }
    }

    let body: RequestBody

    func makeAsyncIterator() -> Iterator {
        Iterator(upstream: body.makeAsyncIterator())
    }
}
