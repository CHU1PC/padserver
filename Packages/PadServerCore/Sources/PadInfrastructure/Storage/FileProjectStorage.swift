import Foundation
import PadApplication
import PadDomain

public actor FileProjectStorage: ProjectStorage {
    public enum Failure: Error {
        case projectNotFound
        case invalidRelease
        case operationInProgress
    }

    private let projects: FileProjectRepository
    private let releases: FileReleaseStore
    private let blobs: FileBlobStore
    private var changingBlobOrRelease = false

    public init(directory: URL) {
        projects = FileProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))
        releases = FileReleaseStore(directory: directory)
        blobs = FileBlobStore(directory: directory.appendingPathComponent("blobs"))
    }

    public func listProjects() throws -> [Project] {
        try projects.listProjects()
    }

    public func saveProject(_ project: Project, routes: [Route]) throws {
        var snapshot = try projects.loadSnapshot()
        Self.replaceProject(project, routes: routes, in: &snapshot)
        try projects.saveSnapshot(snapshot)
    }

    public func registerProject(_ project: Project, routes: [Route]) throws {
        var snapshot = try projects.loadSnapshot()
        var occupied = Set(snapshot.routes.filter { $0.project != project.name }.map(RouteLocation.init))
        for route in routes {
            guard occupied.insert(RouteLocation(route)).inserted else {
                throw RegisterProjectRoutes.Error.duplicateRoute
            }
        }
        Self.replaceProject(project, routes: routes, in: &snapshot)
        try projects.saveSnapshot(snapshot)
    }

    public func projectRunState(for project: ProjectName) throws -> ProjectRunState? {
        try projects.loadSnapshot().runStates[project.value]
    }

    public func saveProjectRunState(_ state: ProjectRunState, for project: ProjectName) throws {
        var snapshot = try projects.loadSnapshot()
        guard snapshot.projects.contains(where: { $0.name == project }) else { throw Failure.projectNotFound }
        snapshot.runStates[project.value] = state
        try projects.saveSnapshot(snapshot)
    }

    public func listRoutes() throws -> [Route] {
        try projects.loadSnapshot().routes
    }

    public func listReleases() async throws -> [Release] {
        try await releases.listReleases()
    }

    public func releaseManifest(for releaseID: ReleaseID) async throws -> ReleaseManifest {
        try await releases.releaseManifest(for: releaseID)
    }

    public func saveRelease(_ release: Release, manifest: ReleaseManifest) async throws {
        try await releases.saveRelease(release, manifest: manifest)
    }

    public func activateRelease(_ releaseID: ReleaseID, for project: ProjectName) async throws {
        guard !changingBlobOrRelease else { throw Failure.operationInProgress }
        changingBlobOrRelease = true
        defer { changingBlobOrRelease = false }
        guard try projects.listProjects().contains(where: { $0.name == project }) else {
            throw Failure.invalidRelease
        }
        let manifest = try await releases.releaseManifest(for: releaseID)
        for file in manifest.files {
            guard try await blobs.blobExists(file.blob) else { throw Failure.invalidRelease }
        }
        try await releases.activateRelease(releaseID, for: project)
    }

    public func removeRelease(_ releaseID: ReleaseID) async throws {
        try await releases.removeRelease(releaseID)
    }

    public func blobExists(_ hash: BlobHash) async throws -> Bool {
        try await blobs.blobExists(hash)
    }

    public func saveBlob<Body: HTTPBodyStream>(_ hash: BlobHash, from body: Body) async throws {
        try await blobs.saveBlob(hash, from: body)
    }

    public func openBlob(_ hash: BlobHash) async throws -> BlobBodyStream? {
        try await blobs.openBlob(hash)
    }

    public func listBlobHashes() async throws -> [BlobHash] {
        try await blobs.listBlobHashes()
    }

    public func removeBlob(_ hash: BlobHash) async throws {
        guard !changingBlobOrRelease else { throw Failure.operationInProgress }
        changingBlobOrRelease = true
        defer { changingBlobOrRelease = false }
        try await blobs.removeBlob(hash)
    }

    private static func replaceProject(
        _ project: Project, routes: [Route], in snapshot: inout FileProjectRepository.Snapshot
    ) {
        if let index = snapshot.projects.firstIndex(where: { $0.name == project.name }) {
            snapshot.projects[index] = project
        } else {
            snapshot.projects.append(project)
            snapshot.runStates[project.name.value] = .running
        }
        snapshot.routes.removeAll { $0.project == project.name }
        snapshot.routes.append(contentsOf: routes)
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
