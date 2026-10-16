import Foundation

public struct ShareLink: Codable, Hashable, Sendable {
    public let id: UUID
    public let expiresAt: Date

    public init(id: UUID, expiresAt: Date) {
        self.id = id
        self.expiresAt = expiresAt
    }

    public func isValid(at date: Date) -> Bool {
        date < expiresAt
    }
}
