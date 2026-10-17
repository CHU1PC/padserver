import ArgumentParser
import Foundation
import PadDomain
import PadInterface

struct FileStoreService {
    private let client: AdminClient

    init(client: AdminClient) {
        self.client = client
    }

    func put(path: String, name: String?) async throws -> String {
        let source = URL(filePath: path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path(), isDirectory: &isDirectory), !isDirectory.boolValue
        else {
            throw ValidationError("\(path) is not a file.")
        }
        let storedName = name ?? source.lastPathComponent
        let stored = try await client.uploadFile(name: storedName, from: source)
        return "Uploaded \(stored.name) (\(stored.size) bytes)."
    }

    func get(name: String, output: String?) async throws -> String {
        let destination = URL(filePath: output ?? URL(filePath: name).lastPathComponent)
        try await client.downloadFile(name: name, to: destination)
        return "Saved \(name) to \(destination.path())."
    }

    func list() async throws -> String {
        Self.render(try await client.listFiles())
    }

    func remove(name: String) async throws -> String {
        try await client.deleteFile(name: name)
        return "Removed \(name)."
    }

    static func render(_ response: AdminFilesResponse) -> String {
        guard !response.files.isEmpty else {
            return "No files."
        }
        let rows = response.files.map { [$0.name, String($0.size)] }
        let table = [["NAME", "SIZE"]] + rows
        let widths = (0..<table[0].count).map { column in table.map { $0[column].count }.max() ?? 0 }
        return table.map { row in
            zip(row, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ")
                .trimmingCharacters(in: .whitespaces)
        }.joined(separator: "\n")
    }
}

private func makeFileStoreService() throws -> FileStoreService {
    FileStoreService(
        client: try AdminClient(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            tokenStore: KeychainTokenStore()
        )
    )
}

struct Files: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Upload, download, list and remove stored files.",
        subcommands: [FilesPut.self, FilesGet.self, FilesList.self, FilesRemove.self]
    )
}

struct FilesPut: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "put",
        abstract: "Upload a local file to the server."
    )

    @Argument(help: "Path of the local file.")
    var path: String

    @Option(help: "Name to store the file under. Defaults to the local file name.")
    var name: String?

    mutating func run() async throws {
        print(try await makeFileStoreService().put(path: path, name: name))
    }
}

struct FilesGet: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "get",
        abstract: "Download a stored file."
    )

    @Argument(help: "Name of the stored file.")
    var name: String

    @Option(help: "Path to save to. Defaults to the file name in the current directory.")
    var output: String?

    mutating func run() async throws {
        print(try await makeFileStoreService().get(name: name, output: output))
    }
}

struct FilesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls",
        abstract: "List the stored files."
    )

    mutating func run() async throws {
        print(try await makeFileStoreService().list())
    }
}

struct FilesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Remove a stored file and revoke its share links."
    )

    @Argument(help: "Name of the stored file.")
    var name: String

    mutating func run() async throws {
        print(try await makeFileStoreService().remove(name: name))
    }
}
