import Foundation
import PadApplication
import PadDomain
import Testing

@Test func storageContractSavesProjectRoutesAndReleaseManifest() async throws {
    let name = try ProjectName("example")
    let project = Project(name: name, kind: .staticSite)
    let host = try RouteHost("example.com")
    let prefix = try RoutePathPrefix("/")
    let route = Route(project: name, host: host, pathPrefix: prefix, target: .staticSite)
    let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046"))
    let releaseID = ReleaseID(id)
    let release = Release(id: releaseID, project: name, state: .preparing)
    let hash = try fixtureBlobHash("sha256-example")
    let manifest = ReleaseManifest(files: [try ReleaseManifestFile(path: "index.html", blob: hash)])
    let storage: any ProjectStorage = InMemoryProjectStorage()

    try await storage.saveProject(project, routes: [route])
    try await storage.saveRelease(release, manifest: manifest)
    #expect(try await storage.listProjects() == [project])
    #expect(try await storage.listRoutes() == [route])
    #expect(try await storage.listReleases() == [release])
    #expect(try await storage.releaseManifest(for: releaseID) == manifest)
}

@Test func storageContractPersistsProjectRunStateWithoutDroppingRoutes() async throws {
    let name = try ProjectName("example")
    let project = Project(name: name, kind: .staticSite)
    let route = Route(
        project: name,
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .staticSite
    )
    let storage: any ProjectStorage = InMemoryProjectStorage()
    try await storage.saveProject(project, routes: [route])

    try await storage.saveProjectRunState(.stopped, for: name)
    #expect(try await storage.projectRunState(for: name) == .stopped)
    #expect(try await storage.listRoutes() == [route])
    try await storage.saveProjectRunState(.running, for: name)
    #expect(try await storage.projectRunState(for: name) == .running)
    #expect(try await storage.listRoutes() == [route])
}

@Test func storageContractStreamsAndRemovesBlobs() async throws {
    let name = try ProjectName("example")
    let id = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046"))
    let releaseID = ReleaseID(id)
    let hash = try fixtureBlobHash("sha256-example")
    let release = Release(id: releaseID, project: name, state: .preparing)
    let manifest = ReleaseManifest(files: [try ReleaseManifestFile(path: "index.html", blob: hash)])
    let storage: any ProjectStorage = InMemoryProjectStorage()

    try await storage.saveRelease(release, manifest: manifest)
    try await storage.saveBlob(hash, from: TestBodyStream(chunks: [Data("first".utf8), Data("second".utf8)]))
    #expect(try await storage.blobExists(hash))
    #expect(try await storage.blobSize(hash) == 11)

    let body = try #require(await storage.openBlob(hash))
    var receivedChunks: [Data] = []
    for try await chunk in body {
        receivedChunks.append(chunk)
    }
    #expect(receivedChunks == [Data("first".utf8), Data("second".utf8)])

    try await storage.activateRelease(releaseID, for: name)
    #expect(try await storage.listReleases() == [Release(id: releaseID, project: name, state: .active)])
    #expect(try await storage.listBlobHashes() == [hash])
    try await storage.removeRelease(releaseID)
    try await storage.removeBlob(hash)
    #expect(try await storage.listReleases().isEmpty)
    #expect(try await storage.listBlobHashes().isEmpty)
}

@Test func storageContractReadsBlobOnDemandOneChunkAtATime() async throws {
    let hash = try fixtureBlobHash("sha256-demand")
    let stream = DemandCountingBlobStream(chunks: [Data("first".utf8), Data("second".utf8)])
    let storage = InMemoryProjectStorage(blobStream: stream.bodyStream())
    let body = try #require(await storage.openBlob(hash))
    var iterator = body.makeAsyncIterator()

    #expect(await stream.readCount == 0)
    #expect(try await iterator.next() == Data("first".utf8))
    #expect(await stream.readCount == 1)
    #expect(try await iterator.next() == Data("second".utf8))
    #expect(await stream.readCount == 2)
    #expect(try await iterator.next() == nil)
    #expect(await stream.readCount == 3)
}

@Test func storageContractActivatesReleaseAtomicallyAndPreservesOldActiveOnFailure() async throws {
    let project = try ProjectName("example")
    let otherProject = try ProjectName("other")
    let firstID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046")))
    let nextID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000047")))
    let otherID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000048")))
    let missingID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000049")))
    let firstHash = try fixtureBlobHash("sha256-first")
    let nextHash = try fixtureBlobHash("sha256-next")
    let storage: any ProjectStorage = InMemoryProjectStorage()
    try await savePreparingRelease(firstID, project: project, hash: firstHash, storage: storage)
    try await storage.saveBlob(firstHash, from: TestBodyStream(chunks: [Data("first".utf8)]))
    try await storage.activateRelease(firstID, for: project)
    try await assertSavingActiveReleaseFails(project: project, hash: firstHash, storage: storage)
    try await savePreparingRelease(nextID, project: project, hash: nextHash, storage: storage)
    try await savePreparingRelease(otherID, project: otherProject, hash: firstHash, storage: storage)
    try await storage.saveBlob(nextHash, from: TestBodyStream(chunks: [Data("next".utf8)]))

    try await storage.activateRelease(nextID, for: project)
    #expect(try await releaseStates(storage) == [firstID: .retired, nextID: .active, otherID: .preparing])
    await #expect(throws: (any Error).self) { try await storage.activateRelease(missingID, for: project) }
    await #expect(throws: (any Error).self) { try await storage.activateRelease(otherID, for: project) }
    #expect(try await releaseStates(storage) == [firstID: .retired, nextID: .active, otherID: .preparing])

    let incompleteID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000050")))
    let incompleteHash = try fixtureBlobHash("sha256-incomplete")
    try await savePreparingRelease(incompleteID, project: project, hash: incompleteHash, storage: storage)
    await #expect(throws: (any Error).self) { try await storage.activateRelease(incompleteID, for: project) }
    #expect(try await releaseStates(storage)[firstID] == .retired)
    #expect(try await releaseStates(storage)[nextID] == .active)
}

private func assertSavingActiveReleaseFails(
    project: ProjectName,
    hash: BlobHash,
    storage: any ProjectStorage
) async throws {
    let id = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000051")))
    let release = Release(id: id, project: project, state: .active)
    let manifest = ReleaseManifest(files: [try ReleaseManifestFile(path: "index.html", blob: hash)])
    await #expect(throws: (any Error).self) { try await storage.saveRelease(release, manifest: manifest) }
    #expect(try await releaseStates(storage).values.filter { $0 == .active }.count == 1)
}

private func savePreparingRelease(
    _ id: ReleaseID,
    project: ProjectName,
    hash: BlobHash,
    storage: any ProjectStorage
) async throws {
    let release = Release(id: id, project: project, state: .preparing)
    let manifest = ReleaseManifest(files: [try ReleaseManifestFile(path: "index.html", blob: hash)])
    try await storage.saveRelease(release, manifest: manifest)
}

private func releaseStates(_ storage: any ProjectStorage) async throws -> [ReleaseID: ReleaseState] {
    Dictionary(uniqueKeysWithValues: try await storage.listReleases().map { ($0.id, $0.state) })
}

private actor InMemoryProjectStorage: ProjectStorage {
    private var projects: [Project] = []
    private var routes: [Route] = []
    private var runStates: [ProjectName: ProjectRunState] = [:]
    private var releases: [Release] = []
    private var manifests: [ReleaseID: ReleaseManifest] = [:]
    private var blobs: [BlobHash: [Data]] = [:]
    private let overrideBlobStream: BlobBodyStream?

    init(blobStream: BlobBodyStream? = nil) {
        overrideBlobStream = blobStream
    }

    func listProjects() throws -> [Project] { projects }

    func saveProject(_ project: Project, routes newRoutes: [Route]) throws {
        projects = [project]
        routes = newRoutes
        runStates[project.name] = .running
    }

    func registerProject(_ project: Project, routes newRoutes: [Route]) throws {
        try saveProject(project, routes: newRoutes)
    }

    func projectRunState(for project: ProjectName) throws -> ProjectRunState? { runStates[project] }

    func saveProjectRunState(_ state: ProjectRunState, for project: ProjectName) throws {
        guard runStates[project] != nil else { throw StorageContractError.projectNotFound }
        runStates[project] = state
    }

    func listRoutes() throws -> [Route] { routes }

    func listReleases() throws -> [Release] { releases }

    func releaseManifest(for releaseID: ReleaseID) throws -> ReleaseManifest {
        try #require(manifests[releaseID])
    }

    func saveRelease(_ release: Release, manifest: ReleaseManifest) throws {
        guard release.state == .preparing, !releases.contains(where: { $0.id == release.id }) else {
            throw StorageContractError.invalidRelease
        }
        releases.append(release)
        manifests[release.id] = manifest
    }

    func activateRelease(_ releaseID: ReleaseID, for project: ProjectName) throws {
        guard let index = releases.firstIndex(where: { $0.id == releaseID }),
            releases[index].project == project,
            releases[index].state == .preparing,
            let manifest = manifests[releaseID],
            manifest.files.allSatisfy({ blobs[$0.blob] != nil })
        else {
            throw StorageContractError.invalidRelease
        }

        let updated = releases.map { release in
            guard release.project == project else { return release }
            let state: ReleaseState
            if release.id == releaseID {
                state = .active
            } else if release.state == .active {
                state = .retired
            } else {
                state = release.state
            }
            return Release(id: release.id, project: release.project, state: state)
        }
        releases = updated
    }

    func removeRelease(_ releaseID: ReleaseID) throws {
        releases.removeAll { $0.id == releaseID }
        manifests.removeValue(forKey: releaseID)
    }

    func blobExists(_ hash: BlobHash) throws -> Bool { blobs[hash] != nil }

    func blobSize(_ hash: BlobHash) throws -> Int64? {
        blobs[hash].map { chunks in chunks.reduce(0) { $0 + Int64($1.count) } }
    }

    func saveBlob<Body: HTTPBodyStream>(_ hash: BlobHash, from body: Body) async throws {
        var chunks: [Data] = []
        for try await chunk in body {
            chunks.append(chunk)
        }
        blobs[hash] = chunks
    }

    func openBlob(_ hash: BlobHash) throws -> BlobBodyStream? {
        if let overrideBlobStream { return overrideBlobStream }
        guard let chunks = blobs[hash] else { return nil }
        return BlobBodyStream {
            let cursor = BlobChunkCursor(chunks: chunks, counter: BlobReadCounter())
            return { await cursor.next() }
        }
    }

    func listBlobHashes() throws -> [BlobHash] { Array(blobs.keys) }

    func removeBlob(_ hash: BlobHash) throws { blobs.removeValue(forKey: hash) }
}

private enum StorageContractError: Error {
    case projectNotFound
    case invalidRelease
}

private struct DemandCountingBlobStream {
    let chunks: [Data]
    let counter = BlobReadCounter()

    var readCount: Int { get async { await counter.readCount } }

    func bodyStream() -> BlobBodyStream {
        BlobBodyStream {
            let cursor = BlobChunkCursor(chunks: chunks, counter: counter)
            return { await cursor.next() }
        }
    }
}

private actor BlobReadCounter {
    private(set) var readCount = 0

    func recordRead() { readCount += 1 }
}

private actor BlobChunkCursor {
    private let chunks: [Data]
    private let counter: BlobReadCounter
    private var index = 0

    init(chunks: [Data], counter: BlobReadCounter) {
        self.chunks = chunks
        self.counter = counter
    }

    func next() async -> Data? {
        await counter.recordRead()
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return chunks[index]
    }
}

private struct TestBodyStream: HTTPBodyStream {
    struct Iterator: AsyncIteratorProtocol, Sendable {
        private let chunks: [Data]
        private var index = 0

        init(chunks: [Data]) { self.chunks = chunks }

        mutating func next() throws -> Data? {
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            return chunks[index]
        }
    }

    let chunks: [Data]

    func makeAsyncIterator() -> Iterator { Iterator(chunks: chunks) }
}
