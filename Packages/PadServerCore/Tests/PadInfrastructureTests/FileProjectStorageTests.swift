import CryptoKit
import Foundation
import PadApplication
import PadDomain
import PadInfrastructure
import Testing

@Test func fileProjectStoragePersistsProjectsRoutesAndRunState() async throws {
    try await withProjectStorageDirectory { directory in
        let storage: any ProjectStorage = FileProjectStorage(directory: directory)
        let project = try projectFixture("site")
        let route = try routeFixture(project: project.name, host: "site.example.com")

        try await storage.registerProject(project, routes: [route])
        try await storage.saveProjectRunState(.stopped, for: project.name)

        let reopened: any ProjectStorage = FileProjectStorage(directory: directory)
        #expect(try await reopened.listProjects() == [project])
        #expect(try await reopened.listRoutes() == [route])
        #expect(try await reopened.projectRunState(for: project.name) == .stopped)
    }
}

@Test func fileProjectStorageRejectsDuplicateRoutesWithoutChangingRegistration() async throws {
    try await withProjectStorageDirectory { directory in
        let storage: any ProjectStorage = FileProjectStorage(directory: directory)
        let first = try projectFixture("first")
        let second = try projectFixture("second")
        let route = try routeFixture(project: first.name, host: "shared.example.com")
        try await storage.registerProject(first, routes: [route])
        let duplicate = try routeFixture(project: second.name, host: "shared.example.com")

        await #expect(throws: RegisterProjectRoutes.Error.duplicateRoute) {
            try await storage.registerProject(second, routes: [duplicate])
        }

        let reopened: any ProjectStorage = FileProjectStorage(directory: directory)
        #expect(try await reopened.listProjects() == [first])
        #expect(try await reopened.listRoutes() == [route])
    }
}

@Test func fileProjectStorageRejectsMissingProjectWithoutSwitchingActiveRelease() async throws {
    try await withProjectStorageDirectory { directory in
        let storage: any ProjectStorage = FileProjectStorage(directory: directory)
        let existing = try projectFixture("site")
        let missing = try projectFixture("missing")
        let oldID = ReleaseID(UUID())
        let releaseID = ReleaseID(UUID())
        let data = Data("old".utf8)
        let hash = try hashFixture(data)
        try await storage.saveProject(existing, routes: [])
        try await storage.saveBlob(hash, from: OneChunkBody(data: data))
        try await saveRelease(oldID, project: existing.name, hash: hash, storage: storage)
        try await storage.activateRelease(oldID, for: existing.name)
        try await saveRelease(releaseID, project: missing.name, hash: hash, storage: storage)

        await #expect(throws: FileProjectStorage.Failure.invalidRelease) {
            try await storage.activateRelease(releaseID, for: missing.name)
        }
        #expect(try await releaseState(oldID, storage: storage) == .active)
        #expect(try await releaseState(releaseID, storage: storage) == .preparing)
    }
}

@Test func fileProjectStorageValidatesBlobsBeforeSwitchingActiveRelease() async throws {
    try await withProjectStorageDirectory { directory in
        let storage: any ProjectStorage = FileProjectStorage(directory: directory)
        let project = try projectFixture("site")
        let oldID = ReleaseID(UUID())
        let nextID = ReleaseID(UUID())
        let oldData = Data("old".utf8)
        let nextData = Data("next".utf8)
        let oldHash = try hashFixture(oldData)
        let nextHash = try hashFixture(nextData)
        try await storage.saveProject(project, routes: [])
        try await storage.saveBlob(oldHash, from: OneChunkBody(data: oldData))
        #expect(try await storage.blobSize(oldHash) == Int64(oldData.count))
        try await storage.saveBlob(nextHash, from: OneChunkBody(data: nextData))
        try await saveRelease(oldID, project: project.name, hash: oldHash, storage: storage)
        try await saveRelease(nextID, project: project.name, hash: nextHash, storage: storage)
        try await storage.activateRelease(oldID, for: project.name)

        try await storage.removeBlob(nextHash)
        await #expect(throws: FileProjectStorage.Failure.invalidRelease) {
            try await storage.activateRelease(nextID, for: project.name)
        }
        #expect(try await releaseState(oldID, storage: storage) == .active)
        #expect(try await releaseState(nextID, storage: storage) == .preparing)

        try await storage.saveBlob(nextHash, from: OneChunkBody(data: nextData))
        try await storage.activateRelease(nextID, for: project.name)

        let reopened: any ProjectStorage = FileProjectStorage(directory: directory)
        #expect(try await releaseState(oldID, storage: reopened) == .retired)
        #expect(try await releaseState(nextID, storage: reopened) == .active)
        #expect(try await reopened.releaseManifest(for: nextID).files.first?.blob == nextHash)
        #expect(try await reopened.listBlobHashes() == [nextHash, oldHash].sorted { $0.value < $1.value })
    }
}

private func projectFixture(_ name: String) throws -> Project {
    Project(name: try ProjectName(name), kind: .staticSite)
}

private func routeFixture(project: ProjectName, host: String) throws -> Route {
    Route(project: project, host: try RouteHost(host), pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
}

private func hashFixture(_ data: Data) throws -> BlobHash {
    try BlobHash(CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
}

private func saveRelease(
    _ id: ReleaseID, project: ProjectName, hash: BlobHash, storage: any ProjectStorage
) async throws {
    let manifest = ReleaseManifest(files: [try ReleaseManifestFile(path: "index.html", blob: hash)])
    try await storage.saveRelease(Release(id: id, project: project, state: .preparing), manifest: manifest)
}

private func releaseState(_ id: ReleaseID, storage: any ProjectStorage) async throws -> ReleaseState? {
    try await storage.listReleases().first(where: { $0.id == id })?.state
}

private func withProjectStorageDirectory(_ operation: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove test directory: \(error)")
        }
    }
    try await operation(directory)
}

private struct OneChunkBody: HTTPBodyStream {
    let data: Data

    func makeAsyncIterator() -> Iterator { Iterator(data: data) }

    struct Iterator: AsyncIteratorProtocol {
        let data: Data
        private var consumed = false

        init(data: Data) {
            self.data = data
        }

        mutating func next() -> Data? {
            guard !consumed else { return nil }
            consumed = true
            return data
        }
    }
}
