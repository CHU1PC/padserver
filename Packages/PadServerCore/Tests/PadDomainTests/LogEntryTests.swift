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

@Test func logEntryDecodesLegacyJSONWithoutProjectAndService() throws {
    let json = #"{"timestamp":0,"source":"web","level":"info","message":"Started"}"#
    let entry = try JSONDecoder().decode(LogEntry.self, from: Data(json.utf8))

    #expect(entry.project == nil)
    #expect(entry.service == nil)
}

@Test func logEntryWithProjectAndServiceRoundTripsThroughJSON() throws {
    let entry = LogEntry(
        timestamp: Date(timeIntervalSince1970: 1_700_000_000),
        source: "web",
        level: .info,
        message: "Started",
        project: "blog",
        service: "web"
    )
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(LogEntry.self, from: data)

    #expect(decoded == entry)
    #expect(decoded.project == "blog")
    #expect(decoded.service == "web")
}

@Test func logEntryOmitsProjectAndServiceKeysWhenNil() throws {
    let entry = LogEntry(timestamp: Date(timeIntervalSince1970: 0), source: "web", level: .info, message: "Started")
    let json = try #require(String(bytes: JSONEncoder().encode(entry), encoding: .utf8))

    #expect(!json.contains("\"project\""))
    #expect(!json.contains("\"service\""))
}
