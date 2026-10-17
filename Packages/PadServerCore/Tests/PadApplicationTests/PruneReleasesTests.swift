import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func pruneReleasesKeepsLatestThreeForEachProjectInStorageOrder() async throws {
    let storage = InMemoryProjectStorage()
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    for project in [first, second] {
        try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [])
    }
    var releases: [Release] = []
    for number in [5, 1, 4, 2, 3] {
        releases.append(try await savePruneRelease(number, project: first, storage: storage))
        releases.append(try await savePruneRelease(number + 10, project: second, storage: storage))
    }

    try await PruneReleases(storage: storage)()

    #expect(try await storage.listReleases() == Array(releases.suffix(6)))
}

@Test func pruneReleasesAlwaysKeepsActiveReleaseOutsideLatestThree() async throws {
    let storage = InMemoryProjectStorage()
    let project = try ProjectName("site")
    try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [])
    let active = try await savePruneRelease(1, project: project, storage: storage)
    try await storage.activateRelease(active.id, for: project)
    var newest: [Release] = []
    for number in 2...5 {
        newest.append(try await savePruneRelease(number, project: project, storage: storage))
    }

    try await PruneReleases(storage: storage)()

    let remaining = try await storage.listReleases()
    #expect(remaining == [Release(id: active.id, project: project, state: .active)] + newest.suffix(3))
}

@Test func pruneReleasesRemovesOnlyBlobsUnreferencedByRetainedReleases() async throws {
    let storage = InMemoryProjectStorage()
    let retainedHashes = try await prepareBlobPruningFixture(storage: storage)

    try await PruneReleases(storage: storage)()

    #expect(Set(try await storage.listBlobHashes()) == retainedHashes)
}

private func prepareBlobPruningFixture(storage: InMemoryProjectStorage) async throws -> Set<BlobHash> {
    let blobs = try PruneBlobFixture()
    let project = try ProjectName("site")
    let other = try ProjectName("other")
    for name in [project, other] {
        try await storage.saveProject(Project(name: name, kind: .staticSite), routes: [])
    }
    for hash in blobs.all {
        try await storage.saveBlob(hash, from: BlobBodyStream { { nil } })
    }
    let active = try await savePruneRelease(
        PruneFixtureID.active, project: project, storage: storage,
        files: [.init(path: "active.html", blob: blobs.active)])
    try await storage.activateRelease(active.id, for: project)
    _ = try await savePruneRelease(
        PruneFixtureID.obsolete, project: project, storage: storage,
        files: [
            .init(path: "old.html", blob: blobs.obsolete),
            .init(path: "shared.html", blob: blobs.shared),
        ])
    for number in PruneFixtureID.recent {
        _ = try await savePruneRelease(
            number, project: project, storage: storage, files: [.init(path: "new.html", blob: blobs.recent)]
        )
    }
    _ = try await savePruneRelease(
        PruneFixtureID.other, project: other, storage: storage,
        files: [.init(path: "shared.html", blob: blobs.shared)])

    return blobs.retained
}

@Test func pruneReleasesHandlesEmptyStorageAndFewerThanThreeReleases() async throws {
    let storage = InMemoryProjectStorage()
    let prune = PruneReleases(storage: storage)
    try await prune()
    #expect(try await storage.listReleases().isEmpty)
    #expect(try await storage.listBlobHashes().isEmpty)
    let project = try ProjectName("site")
    try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [])
    let first = try await savePruneRelease(1, project: project, storage: storage)
    let second = try await savePruneRelease(2, project: project, storage: storage)

    try await prune()

    #expect(try await storage.listReleases() == [first, second])
}

private func savePruneRelease(
    _ number: Int, project: ProjectName, storage: InMemoryProjectStorage,
    files: [ReleaseManifestFile] = []
) async throws -> Release {
    let uuid = try #require(UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)))
    let release = Release(id: ReleaseID(uuid), project: project, state: .preparing)
    try await storage.saveRelease(release, manifest: ReleaseManifest(files: files))
    return release
}

private enum PruneFixtureID {
    static let active = 1
    static let obsolete = 2
    static let recent = 3...5
    static let other = 6
}

private struct PruneBlobFixture {
    let active: BlobHash
    let shared: BlobHash
    let recent: BlobHash
    let obsolete: BlobHash
    let orphan: BlobHash

    init() throws {
        active = try fixtureBlobHash("active")
        shared = try fixtureBlobHash("shared")
        recent = try fixtureBlobHash("recent")
        obsolete = try fixtureBlobHash("obsolete")
        orphan = try fixtureBlobHash("orphan")
    }

    var all: [BlobHash] { [active, shared, recent, obsolete, orphan] }
    var retained: Set<BlobHash> { [active, shared, recent] }
}
