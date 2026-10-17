import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadInterface

public struct FileListController: Sendable {
    private let manageFiles: ManageFiles

    public init(manageFiles: ManageFiles) {
        self.manageFiles = manageFiles
    }

    public func addRoutes(to router: Router<AdminRequestContext>) {
        router.get("/v1/files", use: list)
        router.delete("/v1/files/{name}", use: delete)
    }

    private func list(_ request: Request, context: AdminRequestContext) async throws -> Response {
        let body = AdminFilesResponse(files: try await manageFiles.list())
        let data = try AdminAPIJSON.makeEncoder().encode(body)
        return Response(
            status: .ok, headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func delete(_ request: Request, context: AdminRequestContext) async throws -> Response {
        let name = context.parameters.get("name") ?? ""
        guard try await manageFiles.list().contains(where: { $0.name == name }) else {
            let body = AdminErrorResponse(error: AdminError(code: .fileNotFound, message: "File was not found."))
            let data = try AdminAPIJSON.makeEncoder().encode(body)
            return Response(
                status: .notFound, headers: [.contentType: "application/json"],
                body: .init(byteBuffer: ByteBuffer(bytes: data)))
        }
        try await manageFiles.delete(named: name)
        return Response(status: .noContent)
    }
}
