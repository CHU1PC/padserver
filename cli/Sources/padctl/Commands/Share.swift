import ArgumentParser
import Foundation
import PadInterface

struct ShareLinkService {
    private static let secondsPerHour: TimeInterval = 3_600

    private let client: AdminClient
    private let now: @Sendable () -> Date

    init(client: AdminClient, now: @escaping @Sendable () -> Date = Date.init) {
        self.client = client
        self.now = now
    }

    func create(fileName: String, expiresInHours: Int) async throws -> String {
        guard expiresInHours > 0 else {
            throw ValidationError("The expiry must be a positive number of hours.")
        }
        let expiresAt = now().addingTimeInterval(TimeInterval(expiresInHours) * Self.secondsPerHour)
        let issued = try await client.issueShareLink(fileName: fileName, expiresAt: expiresAt)
        return """
            Share link \(issued.shareLink.id.uuidString) for \(fileName) expires at \
            \(issued.shareLink.expiresAt.formatted(.iso8601)).
            Secret (shown only once): \(issued.secret)
            """
    }

    func list() async throws -> String {
        Self.render(try await client.listShareLinks())
    }

    func revoke(id: String) async throws -> String {
        guard let uuid = UUID(uuidString: id) else {
            throw ValidationError("The share link id must be a UUID.")
        }
        try await client.revokeShareLink(id: uuid)
        return "Share link \(uuid.uuidString) was revoked."
    }

    static func render(_ response: AdminShareLinksResponse) -> String {
        guard !response.shareLinks.isEmpty else {
            return "No share links."
        }
        let rows = response.shareLinks.map { [$0.id.uuidString, $0.fileName, $0.expiresAt.formatted(.iso8601)] }
        let table = [["ID", "FILE", "EXPIRES"]] + rows
        let widths = (0..<table[0].count).map { column in table.map { $0[column].count }.max() ?? 0 }
        return table.map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

private func makeShareLinkService() throws -> ShareLinkService {
    ShareLinkService(
        client: try AdminClient(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            tokenStore: KeychainTokenStore()
        )
    )
}

struct Share: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Issue, list and revoke share links for stored files.",
        subcommands: [ShareCreate.self, ShareList.self, ShareRevoke.self]
    )
}

struct ShareCreate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Issue a share link for a stored file."
    )

    @Argument(help: "Name of the stored file.")
    var file: String

    @Option(name: .customLong("expires-in-hours"), help: "Hours until the link expires.")
    var expiresInHours: Int

    mutating func run() async throws {
        print(try await makeShareLinkService().create(fileName: file, expiresInHours: expiresInHours))
    }
}

struct ShareList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List the issued share links."
    )

    mutating func run() async throws {
        print(try await makeShareLinkService().list())
    }
}

struct ShareRevoke: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "revoke",
        abstract: "Revoke a share link."
    )

    @Argument(help: "Id of the share link.")
    var id: String

    mutating func run() async throws {
        print(try await makeShareLinkService().revoke(id: id))
    }
}
