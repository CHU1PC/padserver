import Foundation

public struct ReleaseID: Hashable, Codable, Sendable {
    public let value: UUID

    public init(_ value: UUID) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        value = try container.decode(UUID.self)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public enum ReleaseState: String, Codable, Hashable, Sendable {
    case preparing
    case active
    case retired
}

public struct Release: Hashable, Codable, Sendable {
    public let id: ReleaseID
    public let project: ProjectName
    public let state: ReleaseState

    public init(id: ReleaseID, project: ProjectName, state: ReleaseState) {
        self.id = id
        self.project = project
        self.state = state
    }
}
