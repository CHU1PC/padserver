import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
@testable import PadInfrastructure
import PadTestSupport
import Testing

private enum ShareTestConstants {
    static let now = Date(timeIntervalSinceReferenceDate: 0)
    static let validity: TimeInterval = 3600
    static let fileName = "report.txt"
    static let content = "0123456789"
    static let linkID = UUID(uuidString: "00000000-0000-0000-0000-000000000001") ?? UUID()
}

private struct ShareFixture {
    let fileStore: InMemoryFileStore
    let linkStore: InMemoryShareLinkStore
    let shareLinks: ShareLinks
}

@Test func shareLinkResponderServesFileForValidSecret() async throws {
    let fixture = try await shareFixture()
    let issued = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    try await shareApplication(fixture).test(.router) { client in
        let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/plain")
        #expect(response.headers[.acceptRanges] == "bytes")
        #expect(String(buffer: response.body) == ShareTestConstants.content)
    }
}

@Test func shareLinkResponderServesRange() async throws {
    let fixture = try await shareFixture()
    let issued = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    try await shareApplication(fixture).test(.router) { client in
        let response = try await client.execute(
            uri: "/s/\(issued.secret)", method: .get, headers: [.range: "bytes=2-5"])
        #expect(response.status == .partialContent)
        #expect(response.headers[.contentRange] == "bytes 2-5/10")
        #expect(String(buffer: response.body) == "2345")

        let unsatisfiable = try await client.execute(
            uri: "/s/\(issued.secret)", method: .get, headers: [.range: "bytes=10-"])
        #expect(unsatisfiable.status == .rangeNotSatisfiable)
        #expect(unsatisfiable.headers[.contentRange] == "bytes */10")
    }
}

@Test func shareLinkResponderReturnsNotFoundForUnknownSecret() async throws {
    let fixture = try await shareFixture()
    _ = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    try await shareApplication(fixture).test(.router) { client in
        let response = try await client.execute(uri: "/s/not-a-secret", method: .get)
        #expect(response.status == .notFound)
        #expect(response.body.readableBytes == 0)
    }
}

@Test func shareLinkResponderReturnsNotFoundAfterExpiry() async throws {
    let fixture = try await shareFixture()
    let issued = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    let expiresAt = issued.link.expiresAt
    try await shareApplication(fixture, now: expiresAt.addingTimeInterval(-1)).test(.router) { client in
        let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(response.status == .ok)
    }
    try await shareApplication(fixture, now: expiresAt).test(.router) { client in
        let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(response.status == .notFound)
    }
}

@Test func shareLinkResponderReturnsNotFoundAfterRevoke() async throws {
    let fixture = try await shareFixture()
    let issued = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    try await fixture.shareLinks.revoke(id: issued.link.id)
    try await shareApplication(fixture).test(.router) { client in
        let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(response.status == .notFound)
    }
}

@Test func shareLinkResponderDoesNotServeFileWithoutLink() async throws {
    let fixture = try await shareFixture()
    _ = try await fixture.fileStore.saveFile(named: "other.txt", from: shareBody("private"))
    let issued = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    try await shareApplication(fixture).test(.router) { client in
        for path in ["/s/other.txt", "/s/\(issued.secret)/../other.txt", "/other.txt"] {
            let response = try await client.execute(uri: path, method: .get)
            #expect(response.status == .notFound)
            #expect(!String(buffer: response.body).contains("private"))
        }
    }
}

@Test func shareLinkResponderReturnsNotFoundWhenFileWasRemoved() async throws {
    let fixture = try await shareFixture()
    let issued = try await fixture.shareLinks.issue(
        fileName: ShareTestConstants.fileName, validFor: ShareTestConstants.validity)
    try await fixture.fileStore.removeFile(named: ShareTestConstants.fileName)
    try await shareApplication(fixture).test(.router) { client in
        let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(response.status == .notFound)
    }
}

private func shareFixture() async throws -> ShareFixture {
    let fileStore = InMemoryFileStore()
    _ = try await fileStore.saveFile(named: ShareTestConstants.fileName, from: shareBody(ShareTestConstants.content))
    let linkStore = InMemoryShareLinkStore()
    let shareLinks = ShareLinks(
        fileStore: fileStore, linkStore: linkStore,
        timeSource: FixedTimeSource(timestamp: ShareTestConstants.now),
        idGenerator: FixedIDGenerator(id: ShareTestConstants.linkID))
    return ShareFixture(fileStore: fileStore, linkStore: linkStore, shareLinks: shareLinks)
}

private func shareApplication(
    _ fixture: ShareFixture, now: Date = ShareTestConstants.now
) -> Application<CallbackResponder<BasicRequestContext>> {
    let responder = ShareLinkResponder(
        fileStore: fixture.fileStore, linkStore: fixture.linkStore, timeSource: FixedTimeSource(timestamp: now))
    return Application(
        responder: CallbackResponder<BasicRequestContext> { request, _ in
            let prefix = "/s/"
            guard request.uri.path.hasPrefix(prefix) else { return Response(status: .notFound) }
            return try await responder.respond(to: request, secret: String(request.uri.path.dropFirst(prefix.count)))
        })
}

private func shareBody(_ text: String) -> BlobBodyStream {
    BlobBodyStream {
        let cursor = ShareBodyCursor(Data(text.utf8))
        return { await cursor.next() }
    }
}

private actor ShareBodyCursor {
    private var data: Data?

    init(_ data: Data) { self.data = data }

    func next() -> Data? {
        defer { data = nil }
        return data
    }
}
