import Foundation
import PadDomain
import PadTestSupport
import Testing

@testable import PadApplication

private let testLinkID: UUID = {
    guard let id = UUID(uuidString: "00000000-0000-0000-0000-00000000002a") else {
        fatalError("Invalid test UUID")
    }
    return id
}()

private struct StubFileStore: FileStore {
    let files: [StoredFile]

    func file(named name: String) throws -> StoredFile? {
        files.first { $0.name == name }
    }

    func listFiles() throws -> [StoredFile] {
        files
    }

    func saveFile<Body: HTTPBodyStream>(named name: String, from body: Body) throws -> StoredFile {
        throw StubFileStoreError.unsupported
    }

    func openFile(named name: String) throws -> BlobBodyStream? {
        nil
    }

    func removeFile(named name: String) throws {
        throw StubFileStoreError.unsupported
    }
}

private enum StubFileStoreError: Error {
    case unsupported
}

private let storedFileSize: Int64 = 10
private let secretHexLength = 64
private let nowTimestamp: TimeInterval = 1_000
private let now = Date(timeIntervalSince1970: nowTimestamp)

private func makeShareLinks(
    linkStore: InMemoryShareLinkStore,
    files: [String] = ["report.pdf"]
) -> ShareLinks {
    ShareLinks(
        fileStore: StubFileStore(files: files.map { StoredFile(name: $0, size: storedFileSize) }),
        linkStore: linkStore,
        timeSource: FixedTimeSource(timestamp: now),
        idGenerator: FixedIDGenerator(id: testLinkID),
        makeSecret: { "example-secret-one" })
}

@Test func issueReturnsLinkExpiringAfterGivenDuration() async throws {
    let shareLinks = makeShareLinks(linkStore: InMemoryShareLinkStore())

    let issued = try await shareLinks.issue(fileName: "report.pdf", validFor: 3_600)

    #expect(issued.link.id == testLinkID)
    #expect(issued.link.expiresAt == now.addingTimeInterval(3_600))
    #expect(issued.link.isValid(at: now))
    #expect(!issued.link.isValid(at: now.addingTimeInterval(3_600)))
}

@Test func issueStoresOnlyHashOfSecret() async throws {
    let store = InMemoryShareLinkStore()
    let shareLinks = makeShareLinks(linkStore: store)

    let issued = try await shareLinks.issue(fileName: "report.pdf", validFor: 60)

    let hash = ShareLinks.secretHash(of: issued.secret)
    let stored = try await store.link(forSecretHash: hash)
    #expect(stored?.fileName == "report.pdf")
    #expect(stored?.link == issued.link)
    #expect(hash != issued.secret)
    #expect(try await store.link(forSecretHash: issued.secret) == nil)
}

@Test func secretHashIsStableSha256Hex() {
    #expect(
        ShareLinks.secretHash(of: "abc")
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func issueRejectsMissingFileAndStoresNothing() async throws {
    let store = InMemoryShareLinkStore()
    let shareLinks = makeShareLinks(linkStore: store)

    await #expect(throws: ShareLinkError.fileNotFound) {
        try await shareLinks.issue(fileName: "missing.pdf", validFor: 60)
    }
    #expect(try await store.listLinks(forFileNamed: "missing.pdf").isEmpty)
}

@Test func defaultSecretIs256BitHexAndUnique() async throws {
    let shareLinks = ShareLinks(
        fileStore: StubFileStore(files: [StoredFile(name: "report.pdf", size: storedFileSize)]),
        linkStore: InMemoryShareLinkStore(),
        timeSource: FixedTimeSource(timestamp: now),
        idGenerator: FixedIDGenerator(id: testLinkID))

    let first = try await shareLinks.issue(fileName: "report.pdf", validFor: 60)
    let second = try await shareLinks.issue(fileName: "report.pdf", validFor: 60)

    #expect(first.secret.count == secretHexLength)
    #expect(first.secret.allSatisfy { $0.isHexDigit })
    #expect(first.secret != second.secret)
}

@Test func revokeRemovesOnlyTheGivenLink() async throws {
    let store = InMemoryShareLinkStore()
    let shareLinks = makeShareLinks(linkStore: store)
    let issued = try await shareLinks.issue(fileName: "report.pdf", validFor: 60)
    let otherLink = StoredShareLink(
        link: ShareLink(id: UUID(), expiresAt: now.addingTimeInterval(60)),
        fileName: "report.pdf", secretHash: "example-other-hash")
    try await store.saveLink(otherLink)

    try await shareLinks.revoke(id: issued.link.id)

    #expect(try await store.link(forSecretHash: ShareLinks.secretHash(of: issued.secret)) == nil)
    #expect(try await store.link(forSecretHash: "example-other-hash") == otherLink)
}

@Test func revokeUnknownLinkSucceeds() async throws {
    let shareLinks = makeShareLinks(linkStore: InMemoryShareLinkStore())

    try await shareLinks.revoke(id: testLinkID)
}
