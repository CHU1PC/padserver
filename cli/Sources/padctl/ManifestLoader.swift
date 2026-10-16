import Foundation
import PadDomain
import TOMLDecoder

enum ManifestLoader {
    static func load(from toml: String) throws -> ProjectManifest {
        let rawManifest: RawManifest
        do {
            rawManifest = try TOMLDecoder().decode(RawManifest.self, from: toml)
        } catch {
            throw makeDecodingError(error, source: toml)
        }

        let name = try makeName(from: rawManifest.name, source: toml)
        let routes = try makeRoutes(from: rawManifest.routes, name: name, source: toml)
        return try makeProjectManifest(rawManifest, name: name, routes: routes, source: toml)
    }

    private static func makeName(from value: String, source: String) throws -> ProjectName {
        do {
            return try ProjectName(value)
        } catch {
            throw ManifestLoadingError(
                description: "Line \(sourceLine(for: "name", routeIndex: nil, in: source)): Invalid project name.")
        }
    }

    private static func makeRoutes(from rawRoutes: [RawRoute], name: ProjectName, source: String) throws -> [Route] {
        try rawRoutes.enumerated().map { index, rawRoute in
            try makeRoute(rawRoute, index: index, name: name, source: source)
        }
    }

    private static func makeRoute(_ rawRoute: RawRoute, index: Int, name: ProjectName, source: String) throws -> Route {
        let host = try makeHost(rawRoute.host, index: index, source: source)
        let pathPrefix = try makePathPrefix(rawRoute.pathPrefix, index: index, source: source)
        return Route(project: name, host: host, pathPrefix: pathPrefix, target: .staticSite)
    }

    private static func makeHost(_ value: String, index: Int, source: String) throws -> RouteHost {
        do {
            return try RouteHost(value)
        } catch {
            let line = sourceLine(for: "host", routeIndex: index, in: source)
            throw ManifestLoadingError(description: "Line \(line): Invalid route host.")
        }
    }

    private static func makePathPrefix(_ value: String, index: Int, source: String) throws -> RoutePathPrefix {
        do {
            return try RoutePathPrefix(value)
        } catch {
            let line = sourceLine(for: "path_prefix", routeIndex: index, in: source)
            throw ManifestLoadingError(description: "Line \(line): Invalid route path prefix.")
        }
    }

    private static func makeProjectManifest(
        _ rawManifest: RawManifest,
        name: ProjectName,
        routes: [Route],
        source: String
    ) throws -> ProjectManifest {
        do {
            return try ProjectManifest(name: name, root: rawManifest.root, routes: routes)
        } catch ProjectManifest.ValidationError.invalidRoot {
            throw ManifestLoadingError(
                description: "Line \(sourceLine(for: "root", routeIndex: nil, in: source)): Invalid static site root.")
        } catch ProjectManifest.ValidationError.noRoutes {
            let line = sourceLine(for: "routes", routeIndex: nil, in: source)
            throw ManifestLoadingError(description: "Line \(line): At least one route is required.")
        } catch {
            throw ManifestLoadingError(description: "Line 1: Invalid project manifest.")
        }
    }

    private static func makeDecodingError(_ error: any Error, source: String) -> ManifestLoadingError {
        let detail = underlyingError(in: error).map { String(describing: $0) } ?? String(describing: error)
        if lineNumber(in: detail) != nil {
            return ManifestLoadingError(description: "Invalid TOML: \(detail)")
        }

        let field = codingPathField(in: error) ?? "manifest"
        let routeIndex = codingPathRouteIndex(in: error)
        let line = sourceLine(for: field, routeIndex: routeIndex, in: source)
        return ManifestLoadingError(description: "Line \(line): Invalid or missing '\(field)' value.")
    }

    private static func underlyingError(in error: any Error) -> (any Error)? {
        switch error {
        case let DecodingError.dataCorrupted(context),
            let DecodingError.keyNotFound(_, context),
            let DecodingError.typeMismatch(_, context),
            let DecodingError.valueNotFound(_, context):
            context.underlyingError

        default:
            nil
        }
    }

    private static func codingPathField(in error: any Error) -> String? {
        guard case let DecodingError.keyNotFound(key, _) = error else {
            guard case let DecodingError.typeMismatch(_, context) = error,
                let key = context.codingPath.last?.stringValue
            else {
                guard case let DecodingError.valueNotFound(_, context) = error else {
                    return nil
                }
                return context.codingPath.last?.stringValue
            }
            return key
        }
        return key.stringValue
    }

    private static func codingPathRouteIndex(in error: any Error) -> Int? {
        let codingPath: [any CodingKey]
        switch error {
        case let DecodingError.keyNotFound(_, context),
            let DecodingError.typeMismatch(_, context),
            let DecodingError.valueNotFound(_, context),
            let DecodingError.dataCorrupted(context):
            codingPath = context.codingPath

        default:
            return nil
        }
        return codingPath.compactMap(\.intValue).first
    }

    private static func lineNumber(in description: String) -> Int? {
        guard let marker = description.range(of: "(Line "),
            let end = description[marker.upperBound...].firstIndex(of: ")")
        else {
            return nil
        }
        return Int(description[marker.upperBound..<end])
    }

    private static func sourceLine(for key: String, routeIndex: Int?, in source: String) -> Int {
        let lines = source.components(separatedBy: .newlines)
        if key == "routes", routeIndex == nil {
            let firstRouteTable =
                lines.firstIndex {
                    $0.trimmingCharacters(in: .whitespaces).hasPrefix("[[routes]]")
                } ?? lines.endIndex
            return matchingLine(for: key, in: lines, range: lines.startIndex..<firstRouteTable) ?? 1
        }

        if let routeIndex {
            let routeTableStarts = lines.indices.filter {
                lines[$0].trimmingCharacters(in: .whitespaces).hasPrefix("[[routes]]")
            }
            guard routeTableStarts.indices.contains(routeIndex) else {
                return 1
            }
            let start = routeTableStarts[routeIndex]
            let end = routeTableStarts.dropFirst(routeIndex + 1).first ?? lines.endIndex
            return matchingLine(for: key, in: lines, range: start..<end) ?? start + 1
        }

        let firstRouteTable =
            lines.firstIndex {
                $0.trimmingCharacters(in: .whitespaces).hasPrefix("[[routes]]")
            } ?? lines.endIndex
        return matchingLine(for: key, in: lines, range: lines.startIndex..<firstRouteTable) ?? 1
    }

    private static func matchingLine(for key: String, in lines: [String], range: Range<Int>) -> Int? {
        lines[range].firstIndex { line in
            let content = line.trimmingCharacters(in: .whitespaces)
            return content.hasPrefix("\(key) =") || content.hasPrefix("\(key)=")
        }.map { $0 + 1 }
    }

}

private struct RawManifest: Decodable {
    let name: String
    let root: String
    let routes: [RawRoute]
}

private struct RawRoute: Decodable {
    let host: String
    let pathPrefix: String

    private enum CodingKeys: String, CodingKey {
        case host
        case pathPrefix = "path_prefix"
    }
}

private struct ManifestLoadingError: Error, CustomStringConvertible {
    let description: String
}
