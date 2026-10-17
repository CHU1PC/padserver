import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

private let linkIDs = ["00000000-0000-0000-0000-000000000001", "00000000-0000-0000-0000-000000000002"]
private let expiryTimestamp: TimeInterval = 2_000
private let expiry = Date(timeIntervalSince1970: expiryTimestamp)

private func makeLink(id: String, fileName: String) throws -> StoredShareLink {
    let uuid = try #require(UUID(uuidString: id))
    return StoredShareLink(
        link: ShareLink(id: uuid, expiresAt: expiry), fileName: fileName, secretHash: "hash-\(id)")
}

private struct EmptyBody: HTTPBodyStream {
    struct Iterator: AsyncIteratorProtocol, Sendable {
        mutating func next() -> Data? {
            nil
        }
    }

    func makeAsyncIterator() -> Iterator {
        Iterator()
    }
}

private func makeStores(files: [String]) async throws -> (InMemoryFileStore, InMemoryShareLinkStore) {
    let fileStore = InMemoryFileStore()
    for name in files {
        _ = try await fileStore.saveFile(named: name, from: EmptyBody())
    }
    return (fileStore, InMemoryShareLinkStore())
}

@Test func listReturnsStoredFiles() async throws {
    let (fileStore, linkStore) = try await makeStores(files: ["b.txt", "a.txt"])
    let manage = ManageFiles(fileStore: fileStore, linkStore: linkStore)

    #expect(try await manage.list() == [StoredFile(name: "a.txt", size: 0), StoredFile(name: "b.txt", size: 0)])
}

@Test func listReturnsEmptyWhenNoFiles() async throws {
    let (fileStore, linkStore) = try await makeStores(files: [])
    #expect(try await ManageFiles(fileStore: fileStore, linkStore: linkStore).list().isEmpty)
}

@Test func deleteRemovesFileAndItsShareLinks() async throws {
    let (fileStore, linkStore) = try await makeStores(files: ["a.txt"])
    try await linkStore.saveLink(makeLink(id: linkIDs[0], fileName: "a.txt"))
    try await linkStore.saveLink(makeLink(id: linkIDs[1], fileName: "a.txt"))
    let manage = ManageFiles(fileStore: fileStore, linkStore: linkStore)

    try await manage.delete(named: "a.txt")

    #expect(try await fileStore.file(named: "a.txt") == nil)
    #expect(try await linkStore.listLinks(forFileNamed: "a.txt").isEmpty)
    #expect(try await linkStore.link(forSecretHash: "hash-\(linkIDs[0])") == nil)
}

@Test func deleteKeepsOtherFilesAndTheirLinks() async throws {
    let (fileStore, linkStore) = try await makeStores(files: ["a.txt", "b.txt"])
    let kept = try makeLink(id: linkIDs[1], fileName: "b.txt")
    try await linkStore.saveLink(makeLink(id: linkIDs[0], fileName: "a.txt"))
    try await linkStore.saveLink(kept)
    let manage = ManageFiles(fileStore: fileStore, linkStore: linkStore)

    try await manage.delete(named: "a.txt")

    #expect(try await fileStore.listFiles() == [StoredFile(name: "b.txt", size: 0)])
    #expect(try await linkStore.listLinks(forFileNamed: "b.txt") == [kept])
}

@Test func deleteMissingFileSucceeds() async throws {
    let (fileStore, linkStore) = try await makeStores(files: ["a.txt"])
    let manage = ManageFiles(fileStore: fileStore, linkStore: linkStore)

    try await manage.delete(named: "missing.txt")

    #expect(try await fileStore.listFiles() == [StoredFile(name: "a.txt", size: 0)])
}
