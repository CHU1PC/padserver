import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func planDeploymentOmitsStoredBlobs() async throws {
    let storage = PadTestSupport.InMemoryProjectStorage()
    let storedFile = ReleaseManifestFile(path: "stored.txt", blob: BlobHash("stored"))
    let missingFile = ReleaseManifestFile(path: "missing.txt", blob: BlobHash("missing"))
    try await storage.saveBlob(storedFile.blob, from: EmptyBodyStream())

    let result = try await PlanDeployment(storage: storage).missingBlobs(from: [storedFile, missingFile])

    #expect(result == [missingFile])
}

@Test func planDeploymentReturnsEmptyWhenAllBlobsAreStored() async throws {
    let storage = PadTestSupport.InMemoryProjectStorage()
    let firstFile = ReleaseManifestFile(path: "first.txt", blob: BlobHash("first"))
    let secondFile = ReleaseManifestFile(path: "second.txt", blob: BlobHash("second"))
    try await storage.saveBlob(firstFile.blob, from: EmptyBodyStream())
    try await storage.saveBlob(secondFile.blob, from: EmptyBodyStream())

    let result = try await PlanDeployment(storage: storage).missingBlobs(from: [firstFile, secondFile])

    #expect(result.isEmpty)
}

private struct EmptyBodyStream: HTTPBodyStream {
    struct Iterator: AsyncIteratorProtocol, Sendable {
        mutating func next() -> Data? { nil }
    }

    func makeAsyncIterator() -> Iterator { Iterator() }
}

@Test func planDeploymentReturnsEmptyForNoFiles() async throws {
    let storage = PadTestSupport.InMemoryProjectStorage()

    let result = try await PlanDeployment(storage: storage).missingBlobs(from: [])

    #expect(result.isEmpty)
}

@Test func planDeploymentDeduplicatesByBlobAndPreservesFirstReferenceOrder() async throws {
    let storage = PadTestSupport.InMemoryProjectStorage()
    let firstFile = ReleaseManifestFile(path: "first.txt", blob: BlobHash("shared"))
    let duplicateFile = ReleaseManifestFile(path: "duplicate.txt", blob: BlobHash("shared"))
    let nextFile = ReleaseManifestFile(path: "next.txt", blob: BlobHash("next"))

    let result = try await PlanDeployment(storage: storage).missingBlobs(
        from: [firstFile, duplicateFile, nextFile])

    #expect(result == [firstFile, nextFile])
}
