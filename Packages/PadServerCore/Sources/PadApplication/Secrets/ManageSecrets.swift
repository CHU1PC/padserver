import PadDomain

public struct ManageSecrets: Sendable {
    private let store: any SecretStore

    public init(store: any SecretStore) {
        self.store = store
    }

    public func set(_ value: String, named name: String, for project: ProjectName) async throws {
        try await store.setSecret(value, named: name, for: project)
    }

    public func names(for project: ProjectName) async throws -> [String] {
        try await store.secretNames(for: project)
    }

    public func remove(named name: String, for project: ProjectName) async throws {
        try await store.removeSecret(named: name, for: project)
    }
}
