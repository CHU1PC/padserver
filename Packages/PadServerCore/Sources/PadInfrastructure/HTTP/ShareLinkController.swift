import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct ShareLinkController: Sendable {
    // 発行の JSON は期限1つだけなので、1 KiB あれば足りる。
    private static let maximumRequestBytes = 1 << 10

    private let shareLinks: ShareLinks
    private let manageFiles: ManageFiles
    private let linkStore: any ShareLinkStore
    private let timeSource: any TimeSource

    public init(
        shareLinks: ShareLinks, manageFiles: ManageFiles, linkStore: any ShareLinkStore, timeSource: any TimeSource
    ) {
        self.shareLinks = shareLinks
        self.manageFiles = manageFiles
        self.linkStore = linkStore
        self.timeSource = timeSource
    }

    public func addRoutes(to router: Router<AdminRequestContext>) {
        router.post("/v1/files/{name}/share-links", use: issue)
        router.get("/v1/share-links", use: list)
        router.delete("/v1/share-links/{id}", use: revoke)
    }

    private func issue(_ request: Request, context: AdminRequestContext) async throws -> Response {
        let buffer = try await request.body.collect(upTo: Self.maximumRequestBytes)
        let decoded: AdminShareLinkRequest
        do {
            decoded = try AdminAPIJSON.makeDecoder().decode(
                AdminShareLinkRequest.self, from: Data(buffer.readableBytesView))
        } catch {
            return try errorResponse(.badRequest, .invalidRequest, "Request body is invalid.")
        }
        let duration = decoded.expiresAt.timeIntervalSince(timeSource.now())
        let fileName = context.parameters.get("name") ?? ""
        do {
            let issued = try await shareLinks.issue(fileName: fileName, validFor: duration)
            let body = AdminShareLinkIssueResponse(
                shareLink: Self.adminLink(issued.link, fileName: fileName),
                secret: issued.secret)
            return try jsonResponse(body, status: .created)
        } catch ShareLinkError.fileNotFound {
            return try errorResponse(.notFound, .fileNotFound, "File was not found.")
        } catch DiskFileStore.Failure.invalidName {
            return try errorResponse(.badRequest, .invalidRequest, "File name is invalid.")
        }
    }

    private func list(_: Request, context _: AdminRequestContext) async throws -> Response {
        let links = try await allLinks().map { Self.adminLink($0.link, fileName: $0.fileName) }
        return try jsonResponse(AdminShareLinksResponse(shareLinks: links), status: .ok)
    }

    private func revoke(_: Request, context: AdminRequestContext) async throws -> Response {
        guard let id = context.parameters.get("id", as: UUID.self) else {
            return try errorResponse(.badRequest, .invalidRequest, "Share link id is invalid.")
        }
        guard try await allLinks().contains(where: { $0.link.id == id }) else {
            return try errorResponse(.notFound, .shareLinkNotFound, "Share link was not found.")
        }
        try await shareLinks.revoke(id: id)
        return Response(status: .noContent)
    }

    private func allLinks() async throws -> [StoredShareLink] {
        var records: [StoredShareLink] = []
        for file in try await manageFiles.list() {
            records += try await linkStore.listLinks(forFileNamed: file.name)
        }
        return records
    }

    private static func adminLink(_ link: ShareLink, fileName: String) -> AdminShareLink {
        AdminShareLink(id: link.id, fileName: fileName, expiresAt: link.expiresAt)
    }

    private func errorResponse(
        _ status: HTTPResponse.Status, _ code: AdminErrorCode, _ message: String
    ) throws -> Response {
        try jsonResponse(AdminErrorResponse(error: AdminError(code: code, message: message)), status: status)
    }

    private func jsonResponse<Body: Encodable>(_ body: Body, status: HTTPResponse.Status) throws -> Response {
        let data = try AdminAPIJSON.makeEncoder().encode(body)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
