import Foundation
import PadApplication
import PadDomain

public actor InMemoryProjectStorage: ProjectStorage {
    private var projects: [ProjectName: Project] = [:]
    private var projectOrder: [ProjectName] = []
    private var routes: [Route] = []
    private var runStates: [ProjectName: ProjectRunState] = [:]
    private var releases: [ReleaseID: Release] = [:]
    private var releaseOrder: [ReleaseID] = []
    private var manifests: [ReleaseID: ReleaseManifest] = [:]
    private var blobs: [BlobHash: [Data]] = [:]

    public init() {
        // 明示した初期化子で公開 API を安定させます。
    }

    public func listProjects() throws -> [Project] {
        projectOrder.compactMap { projects[$0] }
    }

    public func saveProject(_ project: Project, routes newRoutes: [Route]) throws {
        if projects[project.name] == nil {
            projectOrder.append(project.name)
            runStates[project.name] = .running
        }
        projects[project.name] = project
        routes.removeAll { $0.project == project.name }
        routes.append(contentsOf: newRoutes)
    }

    public func registerProject(_ project: Project, routes newRoutes: [Route]) throws {
        var occupied = Set(routes.filter { $0.project != project.name }.map(RouteLocation.init))
        for route in newRoutes {
            guard occupied.insert(RouteLocation(route)).inserted else {
                throw RegisterProjectRoutes.Error.duplicateRoute
            }
        }
        try saveProject(project, routes: newRoutes)
    }

    public func projectRunState(for project: ProjectName) throws -> ProjectRunState? {
        runStates[project]
    }

    public func saveProjectRunState(_ state: ProjectRunState, for project: ProjectName) throws {
        guard projects[project] != nil else { throw InMemoryStorageError.projectNotFound }
        runStates[project] = state
    }

    public func listRoutes() throws -> [Route] {
        routes
    }

    public func listReleases() throws -> [Release] {
        releaseOrder.compactMap { releases[$0] }
    }

    public func releaseManifest(for releaseID: ReleaseID) throws -> ReleaseManifest {
        guard let manifest = manifests[releaseID] else { throw InMemoryStorageError.releaseNotFound }
        return manifest
    }

    public func saveRelease(_ release: Release, manifest: ReleaseManifest) throws {
        guard release.state == .preparing, releases[release.id] == nil else {
            throw InMemoryStorageError.invalidRelease
        }
        releases[release.id] = release
        releaseOrder.append(release.id)
        manifests[release.id] = manifest
    }

    public func activateRelease(_ releaseID: ReleaseID, for project: ProjectName) throws {
        guard projects[project] != nil,
            let target = releases[releaseID],
            target.project == project,
            target.state == .preparing,
            let manifest = manifests[releaseID],
            manifest.files.allSatisfy({ blobs[$0.blob] != nil })
        else {
            throw InMemoryStorageError.invalidRelease
        }

        for release in releases.values.filter({ $0.project == project && $0.state == .active }) {
            releases[release.id] = Release(id: release.id, project: project, state: .retired)
        }
        releases[releaseID] = Release(id: releaseID, project: project, state: .active)
    }

    public func removeRelease(_ releaseID: ReleaseID) throws {
        releases[releaseID] = nil
        manifests[releaseID] = nil
        releaseOrder.removeAll { $0 == releaseID }
    }

    public func blobExists(_ hash: BlobHash) throws -> Bool {
        blobs[hash] != nil
    }

    public func saveBlob<Body: HTTPBodyStream>(_ hash: BlobHash, from body: Body) async throws {
        var chunks: [Data] = []
        for try await chunk in body {
            chunks.append(chunk)
        }
        blobs[hash] = chunks
    }

    public func openBlob(_ hash: BlobHash) throws -> BlobBodyStream? {
        guard let chunks = blobs[hash] else { return nil }
        return BlobBodyStream {
            let cursor = BlobChunkCursor(chunks: chunks)
            return { await cursor.next() }
        }
    }

    public func listBlobHashes() throws -> [BlobHash] {
        blobs.keys.sorted { $0.value < $1.value }
    }

    public func removeBlob(_ hash: BlobHash) throws {
        blobs[hash] = nil
    }
}

private struct RouteLocation: Hashable {
    let host: RouteHost
    let pathPrefix: RoutePathPrefix

    init(_ route: Route) {
        host = route.host
        pathPrefix = route.pathPrefix
    }
}

private enum InMemoryStorageError: Error {
    case projectNotFound
    case releaseNotFound
    case invalidRelease
}

private actor BlobChunkCursor {
    private let chunks: [Data]
    private var index = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func next() -> Data? {
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return chunks[index]
    }
}
