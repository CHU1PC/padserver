import CryptoKit
import Foundation
import PadApplication
import PadDomain
@testable import PadInfrastructure
import Testing

@Test func fileShareLinkStorePersistsAndFindsLinkBySecretHash() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let record = try shareLinkFixture(1, fileName: "a.zip", secret: "secret-one")
        try await store.saveLink(record)

        let reopened = FileShareLinkStore(directory: directory)
        #expect(try await reopened.link(forSecretHash: record.secretHash) == record)
        #expect(try await reopened.link(forSecretHash: sha256Hex("unknown")) == nil)
    }
}

@Test func fileShareLinkStoreDoesNotWriteRawSecretToDisk() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let secret = "raw-secret-value-1234567890"
        try await store.saveLink(shareLinkFixture(1, fileName: "a.zip", secret: secret))

        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(!contents.isEmpty)
        for name in contents {
            let data = try Data(contentsOf: directory.appendingPathComponent(name))
            #expect(try !#require(String(bytes: data, encoding: .utf8)).contains(secret))
        }
    }
}

@Test func fileShareLinkStoreListsLinksPerFile() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let first = try shareLinkFixture(1, fileName: "a.zip", secret: "s1")
        let second = try shareLinkFixture(2, fileName: "a.zip", secret: "s2")
        let other = try shareLinkFixture(3, fileName: "b.zip", secret: "s3")
        for record in [first, second, other] {
            try await store.saveLink(record)
        }

        #expect(try await store.listLinks(forFileNamed: "a.zip") == [first, second])
        #expect(try await store.listLinks(forFileNamed: "b.zip") == [other])
        #expect(try await store.listLinks(forFileNamed: "none.zip").isEmpty)
    }
}

@Test func fileShareLinkStoreRemovesOneLinkById() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let first = try shareLinkFixture(1, fileName: "a.zip", secret: "s1")
        let second = try shareLinkFixture(2, fileName: "a.zip", secret: "s2")
        try await store.saveLink(first)
        try await store.saveLink(second)

        try await store.removeLink(id: first.link.id)
        try await store.removeLink(id: first.link.id)

        let reopened = FileShareLinkStore(directory: directory)
        #expect(try await reopened.link(forSecretHash: first.secretHash) == nil)
        #expect(try await reopened.listLinks(forFileNamed: "a.zip") == [second])
    }
}

@Test func fileShareLinkStoreRemovesAllLinksOfFile() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let first = try shareLinkFixture(1, fileName: "a.zip", secret: "s1")
        let second = try shareLinkFixture(2, fileName: "a.zip", secret: "s2")
        let other = try shareLinkFixture(3, fileName: "b.zip", secret: "s3")
        for record in [first, second, other] {
            try await store.saveLink(record)
        }

        try await store.removeLinks(forFileNamed: "a.zip")
        try await store.removeLinks(forFileNamed: "a.zip")

        let reopened = FileShareLinkStore(directory: directory)
        #expect(try await reopened.listLinks(forFileNamed: "a.zip").isEmpty)
        #expect(try await reopened.link(forSecretHash: first.secretHash) == nil)
        #expect(try await reopened.link(forSecretHash: other.secretHash) == other)
    }
}

@Test func fileShareLinkStoreSavingSameIdReplacesRecord() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let original = try shareLinkFixture(1, fileName: "a.zip", secret: "s1")
        let replacement = try shareLinkFixture(1, fileName: "a.zip", secret: "s2")
        try await store.saveLink(original)
        try await store.saveLink(replacement)

        #expect(try await store.listLinks(forFileNamed: "a.zip") == [replacement])
        #expect(try await store.link(forSecretHash: original.secretHash) == nil)
    }
}

@Test func fileShareLinkStoreFailedWriteLeavesFileUnchanged() async throws {
    try await withShareLinkStoreDirectory { directory async throws in
        let store = FileShareLinkStore(directory: directory)
        let first = try shareLinkFixture(1, fileName: "a.zip", secret: "s1")
        try await store.saveLink(first)
        let fileURL = directory.appendingPathComponent("share-links.json")
        let before = try Data(contentsOf: fileURL)
        let failing = FileShareLinkStore(
            directory: directory,
            writeData: { _, _ in
                throw ShareLinkStoreWriteFailure.denied
            })

        await #expect(throws: ShareLinkStoreWriteFailure.self) {
            try await failing.saveLink(shareLinkFixture(2, fileName: "a.zip", secret: "s2"))
        }
        await #expect(throws: ShareLinkStoreWriteFailure.self) {
            try await failing.removeLink(id: first.link.id)
        }

        #expect(try Data(contentsOf: fileURL) == before)
        let reopened = FileShareLinkStore(directory: directory)
        #expect(try await reopened.listLinks(forFileNamed: "a.zip") == [first])
    }
}

private let shareLinkExpiry: TimeInterval = 1_000_000

private enum ShareLinkStoreWriteFailure: Error {
    case denied
}

private func sha256Hex(_ secret: String) -> String {
    SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
}

private func shareLinkFixture(_ number: Int, fileName: String, secret: String) throws -> StoredShareLink {
    let id = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)))
    return StoredShareLink(
        link: ShareLink(id: id, expiresAt: Date(timeIntervalSince1970: shareLinkExpiry)),
        fileName: fileName,
        secretHash: sha256Hex(secret))
}

private func withShareLinkStoreDirectory(_ operation: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        try await operation(directory)
    } catch {
        try FileManager.default.removeItem(at: directory)
        throw error
    }
    try FileManager.default.removeItem(at: directory)
}
