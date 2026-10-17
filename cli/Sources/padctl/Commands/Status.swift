import ArgumentParser
import Foundation
import PadInterface

enum StatusReport {
    static func render(_ response: AdminProjectsResponse) -> String {
        guard !response.projects.isEmpty else {
            return "No projects."
        }
        let rows = response.projects.map { status in
            [
                status.project.name.value,
                status.project.kind.rawValue,
                status.running ? "running" : "stopped",
                status.activeRelease.map { "\($0.id.value) (\($0.state.rawValue))" } ?? "-",
            ]
        }
        let table = [["PROJECT", "KIND", "STATE", "RELEASE"]] + rows
        let widths = (0..<table[0].count).map { column in table.map { $0[column].count }.max() ?? 0 }
        return table.map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show the projects on the server and whether each one is running."
    )

    mutating func run() async throws {
        let client = try AdminClient(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            tokenStore: KeychainTokenStore()
        )
        print(StatusReport.render(try await client.listProjects()))
    }
}
