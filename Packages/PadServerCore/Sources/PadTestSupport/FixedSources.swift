import Foundation
import PadApplication

public struct FixedTimeSource: TimeSource {
    public let timestamp: Date

    public init(timestamp: Date) {
        self.timestamp = timestamp
    }

    public func now() -> Date {
        timestamp
    }
}

public struct FixedIDGenerator: IDGenerator {
    public let id: UUID

    public init(id: UUID) {
        self.id = id
    }

    public func generate() -> UUID {
        id
    }
}
