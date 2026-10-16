import Foundation
import Testing

@testable import PadDomain

@Test func logEntryKeepsTimestampSourceLevelAndMessage() {
    let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
    let entry = LogEntry(timestamp: timestamp, source: "web", level: .info, message: "Started")

    #expect(entry.timestamp == timestamp)
    #expect(entry.source == "web")
    #expect(entry.level == .info)
    #expect(entry.message == "Started")
}

@Test(arguments: [LogLevel.debug, .info, .warning, .error])
func logLevelRoundTripsThroughJSON(level: LogLevel) throws {
    let data = try JSONEncoder().encode(level)
    #expect(try JSONDecoder().decode(LogLevel.self, from: data) == level)
}

@Test func logEntryRoundTripsThroughJSON() throws {
    let entry = LogEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        source: "deploy",
        level: .error,
        message: "Deployment failed"
    )
    let data = try JSONEncoder().encode(entry)

    #expect(try JSONDecoder().decode(LogEntry.self, from: data) == entry)
}
