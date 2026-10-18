import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func commitDeploymentActivatesNewReleaseAndRetiresOldRelease() async throws {
    let project = try ProjectName("example")
    let oldID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046")))
    let newID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000053")))
    let oldHash = try fixtureBlobHash("sha256-old")
    let newHash = try fixtureBlobHash("sha256-new")
    let storage = PadTestSupport.InMemoryProjectStorage()
    try await prepareActiveRelease(oldID, project: project, hash: oldHash, storage: storage)
    try await storage.saveBlob(newHash, from: TestBlobBody(chunks: [Data("new".utf8)]))
    let deployment = CommitDeployment(storage: storage, idGenerator: PadTestSupport.FixedIDGenerator(id: newID.value))

    let result = try await deployment(
        project: projectRecord(project), routes: [], manifest: try manifest(hash: newHash))

    #expect(result == Release(id: newID, project: project, state: .active))
    #expect(
        try await storage.listReleases() == [
            Release(id: oldID, project: project, state: .retired),
            Release(id: newID, project: project, state: .active),
        ])
}

@Test func commitDeploymentRejectsMissingBlobWithoutChangingActiveRelease() async throws {
    let project = try ProjectName("example")
    let oldID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046")))
    let newID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000053")))
    let oldHash = try fixtureBlobHash("sha256-old")
    let missingHash = try fixtureBlobHash("sha256-missing")
    let incompleteManifest = ReleaseManifest(files: [
        try ReleaseManifestFile(path: "index.html", blob: oldHash),
        try ReleaseManifestFile(path: "missing.html", blob: missingHash),
    ])
    let storage = PadTestSupport.InMemoryProjectStorage()
    try await prepareActiveRelease(oldID, project: project, hash: oldHash, storage: storage)
    let deployment = CommitDeployment(storage: storage, idGenerator: PadTestSupport.FixedIDGenerator(id: newID.value))

    do {
        _ = try await deployment(project: projectRecord(project), routes: [], manifest: incompleteManifest)
        Issue.record("Expected a missing blob error")
    } catch let error as CommitDeployment.Failure {
        #expect(error == .blobNotFound(missingHash))
    }

    #expect(try await storage.listReleases() == [Release(id: oldID, project: project, state: .active)])
}

@Test func commitDeploymentPropagatesReleaseSaveFailureWithoutChangingActiveRelease() async throws {
    let project = try ProjectName("example")
    let oldID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046")))
    let oldHash = try fixtureBlobHash("sha256-old")
    let storage = PadTestSupport.InMemoryProjectStorage()
    try await prepareActiveRelease(oldID, project: project, hash: oldHash, storage: storage)
    let deployment = CommitDeployment(storage: storage, idGenerator: PadTestSupport.FixedIDGenerator(id: oldID.value))

    await #expect(throws: (any Error).self) {
        try await deployment(project: projectRecord(project), routes: [], manifest: try manifest(hash: oldHash))
    }

    #expect(try await storage.listReleases() == [Release(id: oldID, project: project, state: .active)])
}

private func prepareActiveRelease(
    _ id: ReleaseID,
    project: ProjectName,
    hash: BlobHash,
    storage: PadTestSupport.InMemoryProjectStorage
) async throws {
    let projectRecord = Project(name: project, kind: .staticSite)
    try await storage.saveProject(projectRecord, routes: [])
    let release = Release(id: id, project: project, state: .preparing)
    try await storage.saveRelease(release, manifest: try manifest(hash: hash))
    try await storage.saveBlob(hash, from: TestBlobBody(chunks: [Data("old".utf8)]))
    try await storage.activateRelease(id, for: project)
}

private func manifest(hash: BlobHash) throws -> ReleaseManifest {
    ReleaseManifest(files: [try ReleaseManifestFile(path: "index.html", blob: hash)])
}

private struct TestBlobBody: HTTPBodyStream {
    let chunks: [Data]

    func makeAsyncIterator() -> Iterator {
        Iterator(chunks: chunks)
    }

    struct Iterator: AsyncIteratorProtocol {
        private let chunks: [Data]
        private var index = 0

        init(chunks: [Data]) {
            self.chunks = chunks
        }

        mutating func next() async throws -> Data? {
            await Task.yield()
            guard index < chunks.count else { return nil }
            defer { index += 1 }
            return chunks[index]
        }
    }
}

@Test func commitDeploymentRegistersUnregisteredProjectWithRoutes() async throws {
    let project = try ProjectName("example")
    let newID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000053")))
    let hash = try fixtureBlobHash("sha256-new")
    let route = try staticRoute(project: project, host: "example.test")
    let storage = PadTestSupport.InMemoryProjectStorage()
    try await storage.saveBlob(hash, from: TestBlobBody(chunks: [Data("new".utf8)]))
    let deployment = CommitDeployment(storage: storage, idGenerator: PadTestSupport.FixedIDGenerator(id: newID.value))

    let result = try await deployment(
        project: projectRecord(project), routes: [route], manifest: try manifest(hash: hash))

    #expect(result == Release(id: newID, project: project, state: .active))
    #expect(try await storage.listProjects() == [projectRecord(project)])
    #expect(try await storage.listRoutes() == [route])
}

@Test func commitDeploymentKeepsExistingRoutesOfRegisteredProject() async throws {
    let project = try ProjectName("example")
    let oldID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000046")))
    let newID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000053")))
    let oldHash = try fixtureBlobHash("sha256-old")
    let existingRoute = try staticRoute(project: project, host: "existing.test")
    let storage = PadTestSupport.InMemoryProjectStorage()
    try await prepareActiveRelease(oldID, project: project, hash: oldHash, storage: storage)
    try await storage.saveProject(projectRecord(project), routes: [existingRoute])
    let deployment = CommitDeployment(storage: storage, idGenerator: PadTestSupport.FixedIDGenerator(id: newID.value))

    _ = try await deployment(
        project: projectRecord(project), routes: [try staticRoute(project: project, host: "new.test")],
        manifest: try manifest(hash: oldHash))

    #expect(try await storage.listRoutes() == [existingRoute])
}

@Test func commitDeploymentRejectsRouteUsedByAnotherProject() async throws {
    let project = try ProjectName("example")
    let other = try ProjectName("other")
    let hash = try fixtureBlobHash("sha256-new")
    let storage = PadTestSupport.InMemoryProjectStorage()
    try await storage.saveBlob(hash, from: TestBlobBody(chunks: [Data("new".utf8)]))
    try await storage.saveProject(
        projectRecord(other), routes: [try staticRoute(project: other, host: "example.test")])
    let deployment = CommitDeployment(storage: storage, idGenerator: PadTestSupport.FixedIDGenerator(id: UUID()))

    await #expect(throws: RegisterProjectRoutes.Error.duplicateRoute) {
        try await deployment(
            project: projectRecord(project), routes: [try staticRoute(project: project, host: "example.test")],
            manifest: try manifest(hash: hash))
    }

    #expect(try await storage.listProjects() == [projectRecord(other)])
    #expect(try await storage.listReleases().isEmpty)
}

private func projectRecord(_ name: ProjectName) -> Project {
    Project(name: name, kind: .staticSite)
}

private func staticRoute(project: ProjectName, host: String) throws -> Route {
    Route(project: project, host: try RouteHost(host), pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
}
