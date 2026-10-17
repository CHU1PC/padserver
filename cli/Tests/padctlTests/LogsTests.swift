import Foundation
import PadDomain
import Testing
@testable import padctl

@Test func logsCommandIsRegistered() throws {
    #expect(try Padctl.parseAsRoot(["logs"]) is Logs)
}

@Test func logsRendersTimestampLevelSourceAndMessage() {
    let entry = LogEntry(
        timestamp: Date(timeIntervalSince1970: 1_792_240_496),
        source: "web",
        level: .warning,
        message: "Slow response"
    )

    #expect(LogLine.render(entry) == "2026-10-17T12:34:56Z warning web Slow response")
}

@Test func logsFollowPrintsEachEntryInOrderAndSendsAuthorization() async throws {
    let first = #"{"timestamp":"2026-10-17T12:34:56Z","source":"web","level":"info","message":"Started"}"#
    let second = #"{"timestamp":"2026-10-17T12:34:57Z","source":"api","level":"error","message":"Failed"}"#
    let server = StubServer(.chunks(status: 200, [Data("\(first)\n\(second)\n".utf8)]))
    var lines: [String] = []

    try await LogLine.follow(client: server.makeClient()) { lines.append($0) }

    let sent = try #require(server.requests.first)
    #expect(sent.path == "/v1/logs/stream")
    #expect(sent.authorization == "Bearer dummy-token")
    #expect(lines == ["2026-10-17T12:34:56Z info web Started", "2026-10-17T12:34:57Z error api Failed"])
}

@Test func logsFollowReportsServerError() async throws {
    let body = #"{"error":{"code":"unauthorized","message":"Unauthorized."}}"#
    let server = StubServer(.json(status: 401, body: body))
    let client = try server.makeClient()

    await #expect(throws: AdminClientError.server(status: 401, code: .unauthorized, message: "Unauthorized.")) {
        try await LogLine.follow(client: client) { line in Issue.record("Unexpected line: \(line)") }
    }
}
