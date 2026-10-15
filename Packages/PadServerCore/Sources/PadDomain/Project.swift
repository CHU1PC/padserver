public struct ProjectName: Hashable, Codable, Sendable {
    public enum ValidationError: Error {
        case invalidName
    }

    // サブドメインにも使えるように、DNS ラベルの長さに合わせる。
    private static let maximumLength = 63

    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty, value.utf8.count <= Self.maximumLength else {
            throw ValidationError.invalidName
        }

        guard let first = value.first, let last = value.last,
            Self.isAlphanumeric(first), Self.isAlphanumeric(last),
            value.allSatisfy({ Self.isAlphanumeric($0) || $0 == "-" })
        else {
            throw ValidationError.invalidName
        }

        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        do {
            try self.init(value)
        } catch {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid project name")
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

public enum ProjectKind: String, Codable, Hashable, Sendable {
    case staticSite
    case compose
}

public struct Project: Codable, Hashable, Sendable {
    public let name: ProjectName
    public let kind: ProjectKind

    public init(name: ProjectName, kind: ProjectKind) {
        self.name = name
        self.kind = kind
    }
}
