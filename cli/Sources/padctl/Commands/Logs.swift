import ArgumentParser
import Foundation
import PadDomain

enum LogLine {
    static func render(_ entry: LogEntry) -> String {
        let timestamp = entry.timestamp.formatted(.iso8601)
        return "\(timestamp) \(entry.level.rawValue) \(entry.source) \(entry.message)"
    }

    static func follow(client: AdminClient, write: (String) -> Void) async throws {
        for try await entry in try await client.streamLogs() {
            write(render(entry))
        }
    }
}

struct Logs: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show recent logs and keep following new ones. Press Ctrl-C to stop."
    )

    mutating func run() async throws {
        let client = try AdminClient(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            tokenStore: KeychainTokenStore()
        )
        try await LogLine.follow(client: client) { line in
            print(line)
            fflush(stdout)
        }
    }
}
