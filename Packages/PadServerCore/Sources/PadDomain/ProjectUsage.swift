import Foundation

public struct ProjectUsage: Hashable, Sendable {
    public enum ValidationError: Error {
        case invalidCPUUsage
        case invalidMemoryBytes
    }

    public let cpuUsage: Double
    public let memoryBytes: Int
    public let measuredAt: Date

    public init(cpuUsage: Double, memoryBytes: Int, measuredAt: Date) throws {
        guard cpuUsage.isFinite, cpuUsage >= 0 else {
            throw ValidationError.invalidCPUUsage
        }
        guard memoryBytes >= 0 else {
            throw ValidationError.invalidMemoryBytes
        }

        self.cpuUsage = cpuUsage
        self.memoryBytes = memoryBytes
        self.measuredAt = measuredAt
    }
}
