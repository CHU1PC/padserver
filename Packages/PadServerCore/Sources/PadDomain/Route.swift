import Foundation

public struct RouteHost: Hashable, Codable, Sendable {
    public enum ValidationError: Error {
        case invalidHost
    }

    public let value: String

    public init(_ value: String) throws {
        var normalized = value.lowercased()
        if normalized.hasSuffix(".") {
            normalized.removeLast()
        }

        let labels = normalized.split(separator: ".", omittingEmptySubsequences: false)
        // 末尾のドットを除いた DNS 名は、区切りのドットを含めて最大 253 バイトにする。
        guard !normalized.isEmpty, normalized.utf8.count <= 253,
            labels.allSatisfy({ label in
                !label.isEmpty && label.utf8.count <= 63
                    && label.first.map(Self.isAlphanumeric) == true
                    && label.last.map(Self.isAlphanumeric) == true
                    && label.allSatisfy({ Self.isAlphanumeric($0) || $0 == "-" })
            })
        else {
            throw ValidationError.invalidHost
        }

        self.value = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch ValidationError.invalidHost {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid route host")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }

    private static func isAlphanumeric(_ character: Character) -> Bool {
        ("a"..."z").contains(character) || ("0"..."9").contains(character)
    }
}

public struct RoutePathPrefix: Hashable, Codable, Sendable {
    public enum ValidationError: Error {
        case invalidPathPrefix
    }

    public let value: String

    public init(_ value: String) throws {
        guard value.hasPrefix("/"), !value.contains("?"), !value.contains("#"),
            !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            throw ValidationError.invalidPathPrefix
        }

        var normalized = value
        while normalized.count > 1 && normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        self.value = normalized
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch ValidationError.invalidPathPrefix {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid route path prefix")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ContainerRouteTarget: Hashable, Codable, Sendable {
    public enum ValidationError: Error {
        case invalidService
        case invalidPort
    }

    public let service: String
    public let port: UInt16

    public init(service: String, port: UInt16) throws {
        guard !service.isEmpty,
            service.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0)
                || ("0"..."9").contains($0) || $0 == "_" || $0 == "-" || $0 == "." })
        else {
            throw ValidationError.invalidService
        }
        guard port > 0 else {
            throw ValidationError.invalidPort
        }

        self.service = service
        self.port = port
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let service = try container.decode(String.self, forKey: .service)
        let port = try container.decode(UInt16.self, forKey: .port)
        do {
            try self.init(service: service, port: port)
        } catch ValidationError.invalidService {
            throw DecodingError.dataCorruptedError(forKey: .service, in: container,
                                                   debugDescription: "Invalid container service")
        } catch ValidationError.invalidPort {
            throw DecodingError.dataCorruptedError(forKey: .port, in: container,
                                                   debugDescription: "Invalid container port")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case service
        case port
    }
}

public enum RouteTarget: Hashable, Codable, Sendable {
    case staticSite
    case container(ContainerRouteTarget)
}

public struct Route: Hashable, Codable, Sendable {
    public let project: ProjectName
    public let host: RouteHost
    public let pathPrefix: RoutePathPrefix
    public let target: RouteTarget

    public init(project: ProjectName, host: RouteHost, pathPrefix: RoutePathPrefix, target: RouteTarget) {
        self.project = project
        self.host = host
        self.pathPrefix = pathPrefix
        self.target = target
    }
}
