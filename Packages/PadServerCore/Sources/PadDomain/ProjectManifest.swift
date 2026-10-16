import Foundation

public struct ProjectManifest: Codable, Hashable, Sendable {
    public enum ValidationError: Error {
        case invalidRoot
        case noRoutes
        case invalidRoute
    }

    public let name: ProjectName
    public let root: String
    public let routes: [Route]

    public init(name: ProjectName, root: String, routes: [Route]) throws {
        guard Self.isValidRoot(root) else {
            throw ValidationError.invalidRoot
        }
        guard !routes.isEmpty else {
            throw ValidationError.noRoutes
        }
        guard routes.allSatisfy({ $0.project == name && $0.target == .staticSite }) else {
            throw ValidationError.invalidRoute
        }

        self.name = name
        self.root = root
        self.routes = routes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(ProjectName.self, forKey: .name)
        let root = try container.decode(String.self, forKey: .root)
        let routeEntries = try container.decode([ProjectManifestRouteEntry].self, forKey: .routes)
        let routes = routeEntries.map {
            Route(project: name, host: $0.host, pathPrefix: $0.pathPrefix, target: .staticSite)
        }

        do {
            try self.init(name: name, root: root, routes: routes)
        } catch ValidationError.invalidRoot {
            throw DecodingError.dataCorruptedError(
                forKey: .root, in: container, debugDescription: "Invalid static site root")
        } catch ValidationError.noRoutes {
            throw DecodingError.dataCorruptedError(
                forKey: .routes, in: container, debugDescription: "Static site routes must not be empty")
        } catch ValidationError.invalidRoute {
            throw DecodingError.dataCorruptedError(
                forKey: .routes, in: container, debugDescription: "Invalid static site route")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(root, forKey: .root)
        try container.encode(routes.map(ProjectManifestRouteEntry.init(route:)), forKey: .routes)
    }

    private static func isValidRoot(_ root: String) -> Bool {
        !root.isEmpty && !root.hasPrefix("/") && !root.split(separator: "/").contains("..")
            && !root.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    private enum CodingKeys: String, CodingKey {
        case name
        case root
        case routes
    }
}

private struct ProjectManifestRouteEntry: Codable {
    let host: RouteHost
    let pathPrefix: RoutePathPrefix

    init(route: Route) {
        host = route.host
        pathPrefix = route.pathPrefix
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case pathPrefix = "path_prefix"
    }
}
