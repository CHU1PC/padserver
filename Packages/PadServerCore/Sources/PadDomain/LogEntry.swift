import Foundation

public enum LogLevel: String, Codable, Hashable, Sendable {
    case debug
    case info
    case warning
    case error
}

public struct LogEntry: Codable, Hashable, Sendable {
    public let timestamp: Date
    public let source: String
    public let level: LogLevel
    public let message: String

    public init(timestamp: Date, source: String, level: LogLevel, message: String) {
        self.timestamp = timestamp
        self.source = source
        self.level = level
        self.message = message
    }
}
