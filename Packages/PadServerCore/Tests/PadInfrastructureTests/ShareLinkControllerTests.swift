import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import PadTestSupport
import Testing

private enum Constants {
    static let linkID = UUID(uuidString: "00000000-0000-4000-8000-000000000002") ?? UUID()
    static let nowTimestamp: TimeInterval = 1_000
    static let expiryTimestamp: TimeInterval = 5_000
    static let now = Date(timeIntervalSince1970: nowTimestamp)
    static let expiresAt = Date(timeIntervalSince1970: expiryTimestamp)
}

private struct ShareLinkControllerFixture {
    let fileStore = InMemoryFileStore()
    let linkStore = InMemoryShareLinkStore()
    let application: Application<RouterResponder<AdminRequestContext>>

    init() {
        let timeSource = FixedTimeSource(timestamp: Constants.now)
        let router = Router(context: AdminRequestContext.self)
        ShareLinkController(
            shareLinks: ShareLinks(
                fileStore: fileStore, linkStore: linkStore, timeSource: timeSource,
                idGenerator: FixedIDGenerator(id: Constants.linkID)),
            manageFiles: ManageFiles(fileStore: fileStore, linkStore: linkStore),
            linkStore: linkStore,
            timeSource: timeSource
        ).addRoutes(to: router)
        application = Application(responder: router.buildResponder())
    }

    func storeFile(_ name: String) async throws {
        _ = try await fileStore.saveFile(named: name, from: BlobBodyStream { { nil } })
    }
}

private func makeLink() -> ShareLink {
    ShareLink(id: Constants.linkID, expiresAt: Constants.expiresAt)
}

private func expiryBody(_ date: Date) throws -> ByteBuffer {
    ByteBuffer(data: try AdminAPIJSON.makeEncoder().encode(AdminShareLinkRequest(expiresAt: date)))
}

private func decodeError(_ body: ByteBuffer) throws -> AdminErrorResponse {
    try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: Data(buffer: body))
}

@Test func shareLinkControllerIssuesLinkAndReturnsSecretOnce() async throws {
    let fixture = ShareLinkControllerFixture()
    try await fixture.storeFile("report.pdf")

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/files/report.pdf/share-links", method: .post,
            body: try expiryBody(Constants.expiresAt))

        #expect(response.status == .created)
        let body = try AdminAPIJSON.makeDecoder().decode(
            AdminShareLinkIssueResponse.self, from: Data(buffer: response.body))
        #expect(
            body.shareLink
                == AdminShareLink(
                    id: Constants.linkID, fileName: "report.pdf",
                    expiresAt: Constants.expiresAt))
        #expect(!body.secret.isEmpty)

        let listed = try await client.execute(uri: "/v1/share-links", method: .get)
        #expect(!String(buffer: listed.body).contains(body.secret))
    }
}

@Test func shareLinkControllerReturnsNotFoundForMissingFile() async throws {
    try await ShareLinkControllerFixture().application.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/files/missing.pdf/share-links", method: .post,
            body: try expiryBody(Constants.expiresAt))

        #expect(response.status == .notFound)
        #expect(try decodeError(response.body).error.code == .fileNotFound)
    }
}

@Test func shareLinkControllerRejectsInvalidIssueRequests() async throws {
    let fixture = ShareLinkControllerFixture()
    try await fixture.storeFile("report.pdf")

    try await fixture.application.test(.router) { client in
        let malformed = try await client.execute(
            uri: "/v1/files/report.pdf/share-links", method: .post, body: ByteBuffer(string: "{"))

        #expect(malformed.status == .badRequest)
        #expect(try decodeError(malformed.body).error.code == .invalidRequest)
        #expect(try await fixture.linkStore.listLinks(forFileNamed: "report.pdf").isEmpty)
    }
}

@Test func shareLinkControllerListsLinksOfAllFiles() async throws {
    let fixture = ShareLinkControllerFixture()
    try await fixture.storeFile("a.txt")
    try await fixture.storeFile("b.txt")
    let first = makeLink()
    try await fixture.linkStore.saveLink(StoredShareLink(link: first, fileName: "b.txt", secretHash: "hash"))

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(uri: "/v1/share-links", method: .get)

        #expect(response.status == .ok)
        let body = try AdminAPIJSON.makeDecoder().decode(
            AdminShareLinksResponse.self, from: Data(buffer: response.body))
        #expect(
            body.shareLinks == [
                AdminShareLink(id: first.id, fileName: "b.txt", expiresAt: first.expiresAt)
            ])
        #expect(!String(buffer: response.body).contains("hash"))
    }
}

@Test func shareLinkControllerRevokesLink() async throws {
    let fixture = ShareLinkControllerFixture()
    try await fixture.storeFile("report.pdf")
    let link = makeLink()
    try await fixture.linkStore.saveLink(StoredShareLink(link: link, fileName: "report.pdf", secretHash: "hash"))

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(uri: "/v1/share-links/\(link.id.uuidString)", method: .delete)

        #expect(response.status == .noContent)
        #expect(response.body.readableBytes == 0)
        #expect(try await fixture.linkStore.listLinks(forFileNamed: "report.pdf").isEmpty)
    }
}

@Test func shareLinkControllerReturnsNotFoundForUnknownLinkAndRejectsBadId() async throws {
    try await ShareLinkControllerFixture().application.test(.router) { client in
        let unknown = try await client.execute(
            uri: "/v1/share-links/\(Constants.linkID.uuidString)", method: .delete)
        let malformed = try await client.execute(uri: "/v1/share-links/not-a-uuid", method: .delete)

        #expect(unknown.status == .notFound)
        #expect(try decodeError(unknown.body).error.code == .shareLinkNotFound)
        #expect(malformed.status == .badRequest)
        #expect(try decodeError(malformed.body).error.code == .invalidRequest)
    }
}

@Test func shareLinkControllerRoutesRequireAdminAuthentication() async throws {
    let fixture = ShareLinkControllerFixture()
    let timeSource = FixedTimeSource(timestamp: Constants.now)
    let application = try AdminServer.makeApplication(
        adminPort: 8081,
        deliveryPort: 8080,
        tailnetAddress: "100.64.0.1",
        authorizeAdmin: AuthorizeAdmin(secretStore: InMemorySecretStore())
    ) { router in
        ShareLinkController(
            shareLinks: ShareLinks(
                fileStore: fixture.fileStore, linkStore: fixture.linkStore, timeSource: timeSource,
                idGenerator: FixedIDGenerator(id: Constants.linkID)),
            manageFiles: ManageFiles(fileStore: fixture.fileStore, linkStore: fixture.linkStore),
            linkStore: fixture.linkStore,
            timeSource: timeSource
        ).addRoutes(to: router)
    }

    try await application.test(.router) { client in
        let list = try await client.execute(uri: "/v1/share-links", method: .get)
        let revoke = try await client.execute(
            uri: "/v1/share-links/\(Constants.linkID.uuidString)", method: .delete)

        #expect(list.status == .unauthorized)
        #expect(revoke.status == .unauthorized)
    }
}
