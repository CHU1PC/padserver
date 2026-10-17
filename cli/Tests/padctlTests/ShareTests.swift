import ArgumentParser
import Foundation
import Testing
@testable import padctl

private let exampleID = "00000000-0000-4000-8000-000000000002"
private let linkJSON = #"{"id":"\#(exampleID)","fileName":"report.pdf","expiresAt":"1970-01-02T01:00:00Z"}"#
private let now = Date(timeIntervalSince1970: 0)

@Test func shareCommandsAreRegistered() throws {
    let create = try #require(
        try Padctl.parseAsRoot(["share", "create", "report.pdf", "--expires-in-hours", "2"]) as? ShareCreate)
    #expect(create.file == "report.pdf")
    #expect(create.expiresInHours == 2)
    #expect(try Padctl.parseAsRoot(["share", "list"]) is ShareList)
    let revoke = try #require(try Padctl.parseAsRoot(["share", "revoke", exampleID]) as? ShareRevoke)
    #expect(revoke.id == exampleID)
}

@Test func shareCreateRequiresExpiry() {
    #expect(throws: (any Error).self) { try Padctl.parseAsRoot(["share", "create", "report.pdf"]) }
}

@Test func createPostsExpiryAndPrintsSecret() async throws {
    let server = StubServer(
        .json(status: 201, body: #"{"shareLink":\#(linkJSON),"secret":"example-secret"}"#))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    let message = try await service.create(fileName: "report.pdf", expiresInHours: 25)

    #expect(server.requests.map(\.method) == ["POST"])
    #expect(server.requests.map(\.path) == ["/v1/files/report.pdf/share-links"])
    let sent = try #require(String(bytes: server.requests[0].body, encoding: .utf8))
    #expect(sent == #"{"expiresAt":"1970-01-02T01:00:00Z"}"#)
    #expect(message.contains(exampleID))
    #expect(message.contains("Secret (shown only once): example-secret"))
}

@Test func createRejectsNonPositiveHoursWithoutRequest() async throws {
    let server = StubServer(.json(status: 201, body: "{}"))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    await #expect(throws: ValidationError.self) { try await service.create(fileName: "report.pdf", expiresInHours: 0) }
    #expect(server.requests.isEmpty)
}

@Test func createReportsMissingFile() async throws {
    let server = StubServer(
        .json(status: 404, body: #"{"error":{"code":"file_not_found","message":"File was not found."}}"#))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    await #expect(throws: AdminClientError.server(status: 404, code: .fileNotFound, message: "File was not found.")) {
        try await service.create(fileName: "missing.pdf", expiresInHours: 1)
    }
}

@Test func listRendersLinksWithoutSecret() async throws {
    let server = StubServer(.json(status: 200, body: #"{"shareLinks":[\#(linkJSON)]}"#))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    let message = try await service.list()

    #expect(server.requests.map(\.method) == ["GET"])
    #expect(server.requests.map(\.path) == ["/v1/share-links"])
    let idColumn = exampleID.count
    #expect(
        message
            == "\("ID".padding(toLength: idColumn, withPad: " ", startingAt: 0))  FILE        EXPIRES\n"
            + "\(exampleID)  report.pdf  1970-01-02T01:00:00Z")
}

@Test func listRendersMessageWhenThereAreNoLinks() async throws {
    let server = StubServer(.json(status: 200, body: #"{"shareLinks":[]}"#))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    #expect(try await service.list() == "No share links.")
}

@Test func revokeSendsDeleteAndReportsRevoked() async throws {
    let server = StubServer(.json(status: 204, body: ""))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    let message = try await service.revoke(id: exampleID)

    #expect(server.requests.map(\.method) == ["DELETE"])
    #expect(server.requests.map(\.path) == ["/v1/share-links/\(exampleID)"])
    #expect(message == "Share link \(exampleID) was revoked.")
}

@Test func revokeRejectsNonUUIDWithoutRequest() async throws {
    let server = StubServer(.json(status: 204, body: ""))
    let service = try ShareLinkService(client: server.makeClient(), now: { now })

    await #expect(throws: ValidationError.self) { try await service.revoke(id: "not-a-uuid") }
    #expect(server.requests.isEmpty)
}
