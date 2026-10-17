import PadDomain

public struct RegisterProjectRoutes: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case duplicateRoute
    }

    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func callAsFunction(_ project: Project, routes: [Route]) async throws {
        try await storage.registerProject(project, routes: routes)
    }
}
