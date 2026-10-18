import PadDomain

public struct GetProjectUsage: Sendable {
    public enum Failure: Error {
        case projectNotFound
    }

    private let storage: any ProjectStorage
    private let usageSource: any UsageSource

    public init(storage: any ProjectStorage, usageSource: any UsageSource) {
        self.storage = storage
        self.usageSource = usageSource
    }

    public func callAsFunction(of project: ProjectName) async throws -> ProjectUsage? {
        guard try await storage.listProjects().contains(where: { $0.name == project }) else {
            throw Failure.projectNotFound
        }
        return try await usageSource.usage(of: project)
    }
}
