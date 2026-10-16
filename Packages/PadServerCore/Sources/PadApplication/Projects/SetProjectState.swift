import PadDomain

public struct SetProjectState: Sendable {
    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func callAsFunction(_ state: ProjectRunState, for project: ProjectName) async throws {
        try await storage.saveProjectRunState(state, for: project)
    }
}
