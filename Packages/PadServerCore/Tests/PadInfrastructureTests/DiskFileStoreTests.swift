import Foundation
import PadApplication
import PadDomain
import PadInfrastructure
import Testing

@Test func diskFileStoreSavesStreamingBodyAndReportsSize() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)

        let saved = try await store.saveFile(named: "report.pdf", from: FileFixtureBody(chunks: ["ab", "c"]))

        #expect(saved == StoredFile(name: "report.pdf", size: 3))
        #expect(try await store.file(named: "report.pdf") == saved)
        #expect(try Data(contentsOf: directory.appendingPathComponent("report.pdf")) == Data("abc".utf8))
    }
}

@Test func diskFileStoreCreatesMissingDirectoryOnSave() async throws {
    try await withFileStoreDirectory { parent async throws in
        let store = DiskFileStore(directory: parent.appendingPathComponent("files", isDirectory: true))

        _ = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["x"]))

        #expect(try await store.listFiles() == [StoredFile(name: "a", size: 1)])
    }
}

@Test func diskFileStoreReplacesExistingFile() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)
        _ = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["old content"]))

        let saved = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["new"]))

        #expect(saved.size == 3)
        #expect(try await store.listFiles() == [StoredFile(name: "a", size: 3)])
    }
}

@Test func diskFileStoreAcceptsEmptyFile() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)

        let saved = try await store.saveFile(named: "empty", from: FileFixtureBody(chunks: []))
        #expect(saved == StoredFile(name: "empty", size: 0))
        let stream = try #require(try await store.openFile(named: "empty"))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }
}

@Test func diskFileStoreReturnsNilForMissingFile() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)

        #expect(try await store.file(named: "missing") == nil)
        #expect(try await store.openFile(named: "missing") == nil)
        #expect(try await store.listFiles().isEmpty)
        try await store.removeFile(named: "missing")
    }
}

@Test func diskFileStoreListsFilesSortedByName() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)
        _ = try await store.saveFile(named: "b", from: FileFixtureBody(chunks: ["22"]))
        _ = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["1"]))

        #expect(try await store.listFiles() == [StoredFile(name: "a", size: 1), StoredFile(name: "b", size: 2)])
    }
}

@Test func diskFileStoreOpensStreamAndRemovesFile() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)
        _ = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["abc"]))
        let stream = try #require(try await store.openFile(named: "a"))
        var iterator = stream.makeAsyncIterator()

        #expect(try await iterator.next() == Data("abc".utf8))
        #expect(try await iterator.next() == nil)

        try await store.removeFile(named: "a")

        #expect(try await store.file(named: "a") == nil)
        #expect(try await store.listFiles().isEmpty)
    }
}

@Test func diskFileStoreRejectsNamesLeavingTheDirectory() async throws {
    try await withFileStoreDirectory { parent async throws in
        let directory = parent.appendingPathComponent("files", isDirectory: true)
        let store = DiskFileStore(directory: directory)
        let names = ["", ".", "..", "../escape", "a/b", "/etc/passwd", "a\0b", ".hidden"]

        for name in names {
            await #expect(throws: DiskFileStore.Failure.invalidName) {
                _ = try await store.saveFile(named: name, from: FileFixtureBody(chunks: ["x"]))
            }
            await #expect(throws: DiskFileStore.Failure.invalidName) { _ = try await store.file(named: name) }
            await #expect(throws: DiskFileStore.Failure.invalidName) { _ = try await store.openFile(named: name) }
            await #expect(throws: DiskFileStore.Failure.invalidName) { try await store.removeFile(named: name) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: parent.path).isEmpty)
    }
}

@Test func diskFileStoreDoesNotRemoveFileOutsideDirectory() async throws {
    try await withFileStoreDirectory { parent async throws in
        let directory = parent.appendingPathComponent("files", isDirectory: true)
        let store = DiskFileStore(directory: directory)
        let outside = parent.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)

        await #expect(throws: DiskFileStore.Failure.invalidName) { try await store.removeFile(named: "../outside") }

        #expect(FileManager.default.fileExists(atPath: outside.path))
    }
}

@Test func diskFileStoreTreatsSymbolicLinkAsMissing() async throws {
    try await withFileStoreDirectory { parent async throws in
        let directory = parent.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DiskFileStore(directory: directory)
        let outside = parent.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"), withDestinationURL: outside)

        #expect(try await store.file(named: "link") == nil)
        #expect(try await store.openFile(named: "link") == nil)
        #expect(try await store.listFiles().isEmpty)
    }
}

@Test func diskFileStoreSaveReplacesSymbolicLinkWithoutWritingThrough() async throws {
    try await withFileStoreDirectory { parent async throws in
        let directory = parent.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DiskFileStore(directory: directory)
        let outside = parent.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"), withDestinationURL: outside)

        _ = try await store.saveFile(named: "link", from: FileFixtureBody(chunks: ["new"]))

        #expect(try Data(contentsOf: outside) == Data("outside".utf8))
        #expect(try await store.file(named: "link") == StoredFile(name: "link", size: 3))
    }
}

@Test func diskFileStoreRemoveDeletesSymbolicLinkOnly() async throws {
    try await withFileStoreDirectory { parent async throws in
        let directory = parent.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = DiskFileStore(directory: directory)
        let outside = parent.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: directory.appendingPathComponent("link"), withDestinationURL: outside)

        try await store.removeFile(named: "link")

        #expect(FileManager.default.fileExists(atPath: outside.path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@Test func diskFileStoreDiscardsInterruptedSaveAndKeepsPreviousFile() async throws {
    try await withFileStoreDirectory { directory async throws in
        let store = DiskFileStore(directory: directory)
        _ = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["old"]))

        await #expect(throws: FileFixtureFailure.interrupted) {
            _ = try await store.saveFile(named: "a", from: FileFixtureBody(chunks: ["new"], failsAtEnd: true))
        }

        #expect(try Data(contentsOf: directory.appendingPathComponent("a")) == Data("old".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["a"])
    }
}

private func withFileStoreDirectory(_ operation: (URL) async throws -> Void) async throws {
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

private struct FileFixtureBody: HTTPBodyStream {
    let chunks: [String]
    let failsAtEnd: Bool

    init(chunks: [String], failsAtEnd: Bool = false) {
        self.chunks = chunks
        self.failsAtEnd = failsAtEnd
    }

    func makeAsyncIterator() -> Iterator { Iterator(chunks: chunks, failsAtEnd: failsAtEnd) }

    struct Iterator: AsyncIteratorProtocol {
        let chunks: [String]
        let failsAtEnd: Bool
        private var index = 0

        init(chunks: [String], failsAtEnd: Bool) {
            self.chunks = chunks
            self.failsAtEnd = failsAtEnd
        }

        mutating func next() async throws -> Data? {
            await Task.yield()
            guard index < chunks.count else {
                if failsAtEnd { throw FileFixtureFailure.interrupted }
                return nil
            }
            defer { index += 1 }
            return Data(chunks[index].utf8)
        }
    }
}

private enum FileFixtureFailure: Error {
    case interrupted
}
