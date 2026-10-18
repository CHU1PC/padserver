import Foundation

@available(macOS 13, iOS 16, *)
extension DockerClient {
    public enum ArchiveError: Error, Equatable, Sendable {
        case notFound
        case readOnlyFileSystem
        case invalidRequest
    }

    private enum ArchiveConstants {
        static let okStatus = 200
        static let badRequestStatus = 400
        static let forbiddenStatus = 403
        static let notFoundStatus = 404
        // 大きな tar だと応答が数分後になるので, 既定の 60 秒より長く待つ (1 日)
        static let transferTimeoutSeconds: TimeInterval = 86_400
    }

    /// tar を, メモリに溜めずに container の `path` (展開先の directory) へ送る.
    public func putArchive(containerID: String, path: String, fromFile tar: URL) async throws {
        let response = try await send(
            method: "PUT", path: "/containers/\(containerID)/archive", query: [URLQueryItem(name: "path", value: path)],
            bodyFile: tar, timeout: ArchiveConstants.transferTimeoutSeconds)
        switch response.status {
        case ArchiveConstants.okStatus: return
        case ArchiveConstants.notFoundStatus: throw ArchiveError.notFound
        case ArchiveConstants.forbiddenStatus: throw ArchiveError.readOnlyFileSystem
        case ArchiveConstants.badRequestStatus: throw ArchiveError.invalidRequest
        default: throw ClientError.unexpectedStatus(response.status)
        }
    }
}
