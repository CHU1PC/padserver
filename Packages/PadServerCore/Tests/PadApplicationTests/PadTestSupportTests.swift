import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func sharedProjectStorageStoresProjectsReleasesAndBlobStreams() async throws {
    let projectName = try ProjectName("example")
    let project = Project(name: projectName, kind: .staticSite)
    let route = Route(
        project: projectName,
        host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"),
        target: .staticSite
    )
    let releaseID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000051")))
    let hash = try fixtureBlobHash("sha256-first")
    let storage: any ProjectStorage = PadTestSupport.InMemoryProjectStorage()

    try await assertProjectRoutesAndRunState(project, route: route, storage: storage)

    try await savePreparingRelease(releaseID, project: projectName, hash: hash, storage: storage)
    try await storage.saveBlob(hash, from: TestBodyStream(chunks: [Data("first".utf8), Data("tail".utf8)]))
    #expect(try await storage.listReleases() == [Release(id: releaseID, project: projectName, state: .preparing)])
    #expect(try await storage.releaseManifest(for: releaseID).files.first?.blob == hash)
    #expect(try await storage.blobExists(hash))
    #expect(try await storage.blobSize(hash) == 9)
    #expect(try await storage.listBlobHashes() == [hash])

    let body = try #require(await storage.openBlob(hash))
    var iterator = body.makeAsyncIterator()
    #expect(try await iterator.next() == Data("first".utf8))
    #expect(try await iterator.next() == Data("tail".utf8))
    #expect(try await iterator.next() == nil)

    try await storage.removeRelease(releaseID)
    #expect(try await storage.listReleases().isEmpty)
    await #expect(throws: (any Error).self) { try await storage.releaseManifest(for: releaseID) }
    try await storage.removeBlob(hash)
    #expect(try await storage.blobExists(hash) == false)
    #expect(try await storage.listBlobHashes().isEmpty)
}

@Test func sharedProjectStorageActivatesReleasesOnlyAfterValidation() async throws {
    let projectName = try ProjectName("example")
    let storage: any ProjectStorage = PadTestSupport.InMemoryProjectStorage()
    try await storage.saveProject(Project(name: projectName, kind: .staticSite), routes: [])
    let firstID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000051")))
    let nextID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000052")))
    let missingBlobID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000053")))
    let absentProjectID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000055")))
    let firstHash = try fixtureBlobHash("sha256-first")
    let nextHash = try fixtureBlobHash("sha256-next")

    try await savePreparingRelease(firstID, project: projectName, hash: firstHash, storage: storage)
    try await savePreparingRelease(nextID, project: projectName, hash: nextHash, storage: storage)
    try await savePreparingRelease(
        missingBlobID, project: projectName, hash: try fixtureBlobHash("sha256-missing"), storage: storage)
    try await saveReleaseForAbsentProject(absentProjectID, hash: firstHash, storage: storage)
    try await storage.saveBlob(firstHash, from: TestBodyStream(chunks: [Data("first".utf8)]))
    try await storage.saveBlob(nextHash, from: TestBodyStream(chunks: [Data("next".utf8)]))
    try await storage.activateRelease(firstID, for: projectName)
    await #expect(throws: (any Error).self) { try await storage.activateRelease(missingBlobID, for: projectName) }
    await #expect(throws: (any Error).self) {
        try await storage.activateRelease(absentProjectID, for: try ProjectName("absent"))
    }
    #expect(try await releaseStates(storage)[firstID] == .active)

    try await storage.activateRelease(nextID, for: projectName)
    #expect(try await releaseStates(storage)[firstID] == .retired)
    #expect(try await releaseStates(storage)[nextID] == .active)
    await #expect(throws: (any Error).self) {
        try await storage.activateRelease(nextID, for: try ProjectName("other"))
    }
    #expect(try await releaseStates(storage)[nextID] == .active)
    #expect(try await storage.releaseManifest(for: nextID).files.first?.blob == nextHash)
}

@Test func sharedSecretStoreSupportsProjectSecretsAndAdminToken() async throws {
    let store: any SecretStore = PadTestSupport.InMemorySecretStore()
    let project = try ProjectName("example")

    #expect(try await store.secret(named: "API_KEY", for: project) == nil)
    try await store.setSecret("first.example.com", named: "API_KEY", for: project)
    try await store.setSecret("second.example.com", named: "API_KEY", for: project)
    try await store.setSecret("other.example.com", named: "OTHER", for: project)
    #expect(try await store.secret(named: "API_KEY", for: project) == "second.example.com")
    #expect(try await store.secretNames(for: project) == ["API_KEY", "OTHER"])
    try await store.removeSecret(named: "API_KEY", for: project)
    #expect(try await store.secret(named: "API_KEY", for: project) == nil)
    #expect(try await store.secretNames(for: project) == ["OTHER"])

    let token = AdminToken("example.com")
    try await store.setAdminToken(token)
    #expect(try await store.adminToken()?.value == token.value)
    let replacement = AdminToken("updated.example.com")
    try await store.setAdminToken(replacement)
    #expect(try await store.adminToken()?.value == replacement.value)
}

@Test func sharedRuntimePortsProvideFixedValuesAndReplayThenDeliverLogs() async throws {
    let timestamp = Date(timeIntervalSince1970: 123)
    let uuid = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000054"))
    let clock: any TimeSource = PadTestSupport.FixedTimeSource(timestamp: timestamp)
    let ids: any IDGenerator = PadTestSupport.FixedIDGenerator(id: uuid)
    #expect(clock.now() == timestamp)
    #expect(ids.generate() == uuid)

    let bus: any LogBus = PadTestSupport.InMemoryLogBus()
    for index in 0..<1_001 {
        await bus.publish(makeLogEntry(index: index, timestamp: timestamp))
    }
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()
    var messages: [String] = []
    for _ in 0..<1_000 {
        messages.append(try #require(await iterator.next()).message)
    }
    #expect(messages == (1...1_000).map { "entry-\($0)" })
    await bus.publish(makeLogEntry(index: 1_001, timestamp: timestamp))
    #expect(await iterator.next()?.message == "entry-1001")
}

@Test func sharedStorageKeepsProjectsAndRunStatesIndependent() async throws {
    let storage = PadTestSupport.InMemoryProjectStorage()
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    let firstProject = Project(name: first, kind: .staticSite)
    let secondProject = Project(name: second, kind: .compose)
    let route = Route(
        project: first, host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"), target: .staticSite
    )
    try await storage.saveProject(firstProject, routes: [route])
    try await storage.saveProjectRunState(.stopped, for: first)
    try await storage.saveProject(secondProject, routes: [])
    #expect(try await storage.listProjects() == [firstProject, secondProject])
    #expect(try await storage.projectRunState(for: first) == .stopped)
    #expect(try await storage.projectRunState(for: second) == .running)
    #expect(try await storage.listRoutes() == [route])
}

@Test func sharedReleaseActivationPreservesOtherProjectsActiveRelease() async throws {
    let storage: any ProjectStorage = PadTestSupport.InMemoryProjectStorage()
    let first = try ProjectName("first")
    let other = try ProjectName("other")
    let oldID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000055")))
    let nextID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000056")))
    let otherID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000057")))
    let hash = try fixtureBlobHash("shared")
    try await storage.saveProject(Project(name: first, kind: .staticSite), routes: [])
    try await storage.saveProject(Project(name: other, kind: .staticSite), routes: [])
    try await storage.saveBlob(hash, from: TestBodyStream(chunks: [Data("content".utf8)]))
    try await savePreparingRelease(oldID, project: first, hash: hash, storage: storage)
    try await savePreparingRelease(nextID, project: first, hash: hash, storage: storage)
    try await savePreparingRelease(otherID, project: other, hash: hash, storage: storage)
    try await storage.activateRelease(oldID, for: first)
    try await storage.activateRelease(otherID, for: other)
    try await storage.activateRelease(nextID, for: first)
    #expect(try await releaseStates(storage) == [oldID: .retired, nextID: .active, otherID: .active])
    await #expect(throws: (any Error).self) { try await storage.activateRelease(nextID, for: other) }
    #expect(try await releaseStates(storage) == [oldID: .retired, nextID: .active, otherID: .active])
}

@Test func sharedSecretsWithTheSameNameStaySeparateAcrossProjects() async throws {
    let store = PadTestSupport.InMemorySecretStore()
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    try await store.setSecret("first.example.com", named: "API_KEY", for: first)
    try await store.setSecret("second.example.com", named: "API_KEY", for: second)
    try await store.removeSecret(named: "API_KEY", for: first)
    #expect(try await store.secretNames(for: first).isEmpty)
    #expect(try await store.secret(named: "API_KEY", for: second) == "second.example.com")
    #expect(try await store.secretNames(for: second) == ["API_KEY"])
}

@Test func sharedLogCancellationDoesNotStopOtherSubscribers() async {
    let bus = PadTestSupport.InMemoryLogBus()
    let stream = await bus.subscribe()
    let other = await bus.subscribe()
    let consumer = Task {
        for await _ in stream {
            // キャンセルで購読を終えるまで受信を続けます。
        }
    }
    consumer.cancel()
    await consumer.value
    let entry = makeLogEntry(index: 0, timestamp: Date(timeIntervalSince1970: 0))
    await bus.publish(entry)
    var iterator = other.makeAsyncIterator()
    #expect(await iterator.next() == entry)
}

@Test func sharedBlobStreamKeepsIndependentPullCursors() async throws {
    let storage = PadTestSupport.InMemoryProjectStorage()
    let hash = try fixtureBlobHash("example")
    let first = Data("first".utf8)
    let second = Data("second".utf8)
    try await storage.saveBlob(hash, from: TestBodyStream(chunks: [first, second]))
    let stream = try #require(await storage.openBlob(hash))
    var left = stream.makeAsyncIterator()
    var right = stream.makeAsyncIterator()
    #expect(try await left.next() == first)
    #expect(try await left.next() == second)
    #expect(try await right.next() == first)
    #expect(try await left.next() == nil)
    #expect(try await right.next() == second)
    #expect(try await right.next() == nil)
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

private func assertProjectRoutesAndRunState(
    _ project: Project,
    route: Route,
    storage: any ProjectStorage
) async throws {
    try await storage.saveProject(project, routes: [route])
    #expect(try await storage.listProjects() == [project])
    #expect(try await storage.projectRunState(for: project.name) == .running)
    try await storage.saveProjectRunState(.stopped, for: project.name)
    #expect(try await storage.projectRunState(for: project.name) == .stopped)
    #expect(try await storage.listRoutes() == [route])
    try await storage.saveProjectRunState(.running, for: project.name)
}

private func saveReleaseForAbsentProject(
    _ id: ReleaseID,
    hash: BlobHash,
    storage: any ProjectStorage
) async throws {
    let project = try ProjectName("absent")
    try await savePreparingRelease(id, project: project, hash: hash, storage: storage)
}

private func releaseStates(_ storage: any ProjectStorage) async throws -> [ReleaseID: ReleaseState] {
    Dictionary(uniqueKeysWithValues: try await storage.listReleases().map { ($0.id, $0.state) })
}

private func makeLogEntry(index: Int, timestamp: Date) -> LogEntry {
    LogEntry(timestamp: timestamp, source: "test", level: .info, message: "entry-\(index)")
}

private struct TestBodyStream: HTTPBodyStream {
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
