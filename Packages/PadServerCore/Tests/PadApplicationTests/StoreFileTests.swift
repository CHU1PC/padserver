import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func storeFileSavesValidNameAndReturnsStoredFile() async throws {
    let store = InMemoryFileStore()
    let storeFile = StoreFile(store: store)

    let saved = try await storeFile.save(
        named: "report.pdf", from: FileTestBodyStream(chunks: [Data("abc".utf8), Data("de".utf8)]))

    #expect(saved == StoredFile(name: "report.pdf", size: 5))
    #expect(try await store.file(named: "report.pdf") == saved)
}

@Test func storeFileOpensSavedFileAsChunkStream() async throws {
    let storeFile = StoreFile(store: InMemoryFileStore())
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    _ = try await storeFile.save(named: "a.txt", from: FileTestBodyStream(chunks: [first, second]))

    let stream = try #require(await storeFile.open(named: "a.txt"))
    var iterator = stream.makeAsyncIterator()
    #expect(try await iterator.next() == first)
    #expect(try await iterator.next() == second)
    #expect(try await iterator.next() == nil)
}

@Test func storeFileOpenReturnsNilForMissingFile() async throws {
    let storeFile = StoreFile(store: InMemoryFileStore())
    #expect(try await storeFile.open(named: "missing.txt") == nil)
}

@Test func storeFileSavesEmptyBody() async throws {
    let storeFile = StoreFile(store: InMemoryFileStore())
    let saved = try await storeFile.save(named: "empty", from: FileTestBodyStream(chunks: []))
    #expect(saved == StoredFile(name: "empty", size: 0))
}

@Test func storeFileReplacesExistingFileWithSameName() async throws {
    let store = InMemoryFileStore()
    let storeFile = StoreFile(store: store)
    _ = try await storeFile.save(named: "a.txt", from: FileTestBodyStream(chunks: [Data("old-content".utf8)]))
    let saved = try await storeFile.save(named: "a.txt", from: FileTestBodyStream(chunks: [Data("new".utf8)]))

    #expect(saved.size == 3)
    #expect(try await store.listFiles() == [saved])
}

@Test(arguments: ["", ".", "..", "a/b", "/a", "../a", "a/..", "a\0b"])
func storeFileRejectsInvalidNamesWithoutSaving(name: String) async throws {
    let store = InMemoryFileStore()
    let storeFile = StoreFile(store: store)

    await #expect(throws: StoreFile.Error.invalidName) {
        try await storeFile.save(named: name, from: FileTestBodyStream(chunks: [Data("x".utf8)]))
    }
    await #expect(throws: StoreFile.Error.invalidName) {
        _ = try await storeFile.open(named: name)
    }
    #expect(try await store.listFiles().isEmpty)
}

private struct FileTestBodyStream: HTTPBodyStream {
    struct Iterator: AsyncIteratorProtocol, Sendable {
        private let chunks: [Data]
        private var index = 0

        init(chunks: [Data]) {
            self.chunks = chunks
        }

        mutating func next() -> Data? {
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            return chunks[index]
        }
    }

    let chunks: [Data]

    func makeAsyncIterator() -> Iterator {
        Iterator(chunks: chunks)
    }
}
