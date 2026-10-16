import PadDomain

public struct ListProjects: Sendable {
    public struct Status: Sendable {
        public let project: Project
        public let activeRelease: Release?
        public let running: Bool
    }

    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func callAsFunction() async throws -> [Status] {
        let projects = try await storage.listProjects()
        let releases = try await storage.listReleases()
        var statuses: [Status] = []
        for project in projects {
            let activeRelease = releases.first { $0.project == project.name && $0.state == .active }
            let running = try await storage.projectRunState(for: project.name) == .running
            statuses.append(Status(project: project, activeRelease: activeRelease, running: running))
        }
        return statuses
    }
}
