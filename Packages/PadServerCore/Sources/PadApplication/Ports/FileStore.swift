import Foundation
import PadDomain

public protocol FileStore: Sendable {
    func file(named name: String) async throws -> StoredFile?
    func listFiles() async throws -> [StoredFile]
    func saveFile<Body: HTTPBodyStream>(named name: String, from body: Body) async throws -> StoredFile
    func openFile(named name: String) async throws -> BlobBodyStream?
    func removeFile(named name: String) async throws
}

public struct StoredShareLink: Codable, Hashable, Sendable {
    public let link: ShareLink
    public let fileName: String
    public let secretHash: String

    public init(link: ShareLink, fileName: String, secretHash: String) {
        self.link = link
        self.fileName = fileName
        self.secretHash = secretHash
    }
}

public protocol ShareLinkStore: Sendable {
    func saveLink(_ record: StoredShareLink) async throws
    func link(forSecretHash secretHash: String) async throws -> StoredShareLink?
    func listLinks(forFileNamed name: String) async throws -> [StoredShareLink]
    func removeLink(id: UUID) async throws
    func removeLinks(forFileNamed name: String) async throws
}
