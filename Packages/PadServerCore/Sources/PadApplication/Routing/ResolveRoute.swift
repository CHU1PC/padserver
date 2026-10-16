import PadDomain

public struct ResolveRoute: Sendable {
    public enum Result: Equatable, Sendable {
        case matched(Route)
        case stopped(ProjectName)
        case notFound
        case ambiguous
    }

    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func callAsFunction(host: RouteHost, path: String) async throws -> Result {
        let routes = try await storage.listRoutes()
        let matchingRoutes = routes.filter { route in
            let prefix = route.pathPrefix.value
            return route.host == host
                && (path == prefix || path.hasPrefix(prefix == "/" ? "/" : prefix + "/"))
        }
        guard let route = matchingRoutes.max(by: { $0.pathPrefix.value.count < $1.pathPrefix.value.count }) else {
            return .notFound
        }
        guard matchingRoutes.filter({ $0.pathPrefix == route.pathPrefix }).count == 1 else {
            return .ambiguous
        }
        switch try await storage.projectRunState(for: route.project) {
        case .running:
            return .matched(route)

        case .stopped:
            return .stopped(route.project)

        case nil:
            return .notFound
        }
    }
}
