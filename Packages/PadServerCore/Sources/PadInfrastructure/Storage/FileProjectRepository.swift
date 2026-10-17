import Darwin
import Foundation
import PadApplication
import PadDomain

public struct FileProjectRepository: Sendable {
    struct Snapshot: Codable, Sendable {
        var projects: [Project] = []
        var routes: [Route] = []
        var runStates: [String: ProjectRunState] = [:]
    }

    private let fileURL: URL
    private let writeTemporaryFile: @Sendable (Data, URL) throws -> Void
    private let renameFile: @Sendable (URL, URL) throws -> Void

    public init(fileURL: URL) {
        self.init(
            fileURL: fileURL,
            writeTemporaryFile: { data, temporaryURL in
                try data.write(to: temporaryURL, options: .withoutOverwriting)
            },
            renameFile: Self.rename
        )
    }

    init(
        fileURL: URL,
        writeTemporaryFile: @escaping @Sendable (Data, URL) throws -> Void,
        renameFile: @escaping @Sendable (URL, URL) throws -> Void
    ) {
        self.fileURL = fileURL
        self.writeTemporaryFile = writeTemporaryFile
        self.renameFile = renameFile
    }

    public func listProjects() throws -> [Project] {
        try loadSnapshot().projects
    }

    func loadSnapshot() throws -> Snapshot {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return Snapshot()
        }
        return try JSONDecoder().decode(Snapshot.self, from: data)
    }

    public func saveProjects(_ projects: [Project]) throws {
        var snapshot = try loadSnapshot()
        snapshot.projects = projects
        try saveSnapshot(snapshot)
    }

    func saveSnapshot(_ snapshot: Snapshot) throws {
        let data = try JSONEncoder().encode(snapshot)
        let temporaryDirectory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let temporaryURL = temporaryDirectory.appendingPathComponent(
            ".\(fileURL.lastPathComponent).\(UUID().uuidString).tmp"
        )
        try writeTemporaryFile(data, temporaryURL)
        try renameFile(temporaryURL, fileURL)
    }

    private static func rename(_ sourceURL: URL, _ destinationURL: URL) throws {
        let result = sourceURL.path.withCString { sourcePath in
            destinationURL.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
}
