import Darwin
import CryptoKit
import Foundation
import PadApplication
import PadDomain
import PadInfrastructure
import Testing

@Test func fileBlobStoreWritesStreamingBodyUnderItsSHA256Name() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let body = BlobFixtureBody(chunks: [Data("a".utf8), Data("bc".utf8)])

        try await store.saveBlob(hash, from: body)

        #expect(try await store.blobExists(hash))
        #expect(try await store.blobSize(hash) == 3)
        #expect(try Data(contentsOf: directory.appendingPathComponent(hash.value)) == Data("abc".utf8))
    }
}

@Test func fileBlobStoreDiscardsMismatchedContentAndTemporaryFile() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")

        await #expect(throws: FileBlobStore.Failure.hashMismatch) {
            try await store.saveBlob(hash, from: BlobFixtureBody(chunks: [Data("wrong".utf8)]))
        }

        #expect(try await !store.blobExists(hash))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }
}

@Test func fileBlobStoreReportsSizeWithoutReadingBlob() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try await store.saveBlob(hash, from: BlobFixtureBody(chunks: [Data("abc".utf8)]))
        let path = directory.appendingPathComponent(hash.value).path
        #expect(Darwin.chmod(path, 0) == 0)

        #expect(try await store.blobSize(hash) == 3)
    }
}

@Test func fileBlobStoreDoesNotDuplicateExistingContent() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let body = BlobFixtureBody(chunks: [Data("abc".utf8)])
        try await store.saveBlob(hash, from: body)

        try await store.saveBlob(hash, from: body)

        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [hash.value])
    }
}

@Test func fileBlobStoreOpensIndependentStreamsAndListsAndRemovesBlob() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try await store.saveBlob(hash, from: BlobFixtureBody(chunks: [Data("abc".utf8)]))
        let stream = try #require(try await store.openBlob(hash))
        var first = stream.makeAsyncIterator()
        var second = stream.makeAsyncIterator()

        #expect(try await first.next() == Data("abc".utf8))
        #expect(try await second.next() == Data("abc".utf8))
        #expect(try await first.next() == nil)
        #expect(try await store.listBlobHashes() == [hash])

        try await store.removeBlob(hash)

        #expect(try await store.openBlob(hash) == nil)
        #expect(try await store.listBlobHashes().isEmpty)
    }
}

@Test func fileBlobStoreDiscardsInterruptedReceiveAndAllowsRetry() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        let interrupted = BlobFixtureBody(chunks: [Data("a".utf8)], failsAtEnd: true)

        await #expect(throws: BlobFixtureFailure.interrupted) {
            try await store.saveBlob(hash, from: interrupted)
        }

        #expect(try await !store.blobExists(hash))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        try await store.saveBlob(hash, from: BlobFixtureBody(chunks: [Data("abc".utf8)]))
        #expect(try await store.blobExists(hash))
    }
}

@Test func fileBlobStoreAcceptsEmptyBlobAndStreamsEndImmediately() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

        try await store.saveBlob(hash, from: BlobFixtureBody(chunks: []))

        #expect(try await store.blobExists(hash))
        let stream = try #require(try await store.openBlob(hash))
        var iterator = stream.makeAsyncIterator()
        #expect(try await iterator.next() == nil)
    }
}

@Test func fileBlobStoreReadsLargeBlobInBoundedChunks() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let data = Data(repeating: UInt8(ascii: "a"), count: 128 * 1024 + 1)
        let hash = try BlobHash(CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        try await store.saveBlob(hash, from: BlobFixtureBody(chunks: [data]))
        let stream = try #require(try await store.openBlob(hash))
        var iterator = stream.makeAsyncIterator()

        #expect(try await iterator.next()?.count == 64 * 1024)
        #expect(try await iterator.next()?.count == 64 * 1024)
        #expect(try await iterator.next() == Data("a".utf8))
        #expect(try await iterator.next() == nil)
    }
}

@Test func fileBlobStoreRejectsHashNamedSymbolicLink() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let outside = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("outside".utf8).write(to: outside)
        do {
            let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
            try FileManager.default.createSymbolicLink(
                at: directory.appendingPathComponent(hash.value), withDestinationURL: outside)

            #expect(try await !store.blobExists(hash))
            #expect(try await store.blobSize(hash) == nil)
            #expect(try await store.openBlob(hash) == nil)
        } catch {
            try FileManager.default.removeItem(at: outside)
            throw error
        }
        try FileManager.default.removeItem(at: outside)
    }
}

@Test func fileBlobStoreRejectsLinkReplacementBeforeFirstPull() async throws {
    try await withBlobStoreDirectory { directory async throws in
        let store = FileBlobStore(directory: directory)
        let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        try await store.saveBlob(hash, from: BlobFixtureBody(chunks: [Data("abc".utf8)]))
        let stream = try #require(try await store.openBlob(hash))
        let outside = directory.appendingPathComponent("outside")
        try Data("outside".utf8).write(to: outside)
        let blobURL = directory.appendingPathComponent(hash.value)
        try FileManager.default.removeItem(at: blobURL)
        try FileManager.default.createSymbolicLink(at: blobURL, withDestinationURL: outside)
        var iterator = stream.makeAsyncIterator()

        await #expect(throws: (any Error).self) {
            try await iterator.next()
        }
    }
}

private func withBlobStoreDirectory(_ operation: (URL) async throws -> Void) async throws {
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

private struct BlobFixtureBody: HTTPBodyStream {
    let chunks: [Data]
    let failsAtEnd: Bool

    init(chunks: [Data], failsAtEnd: Bool = false) {
        self.chunks = chunks
        self.failsAtEnd = failsAtEnd
    }

    func makeAsyncIterator() -> Iterator { Iterator(chunks: chunks, failsAtEnd: failsAtEnd) }

    struct Iterator: AsyncIteratorProtocol {
        let chunks: [Data]
        let failsAtEnd: Bool
        private var index = 0

        init(chunks: [Data], failsAtEnd: Bool) {
            self.chunks = chunks
            self.failsAtEnd = failsAtEnd
        }

        mutating func next() async throws -> Data? {
            await Task.yield()
            guard index < chunks.count else {
                if failsAtEnd { throw BlobFixtureFailure.interrupted }
                return nil
            }
            defer { index += 1 }
            return chunks[index]
        }
    }
}

private enum BlobFixtureFailure: Error {
    case interrupted
}
