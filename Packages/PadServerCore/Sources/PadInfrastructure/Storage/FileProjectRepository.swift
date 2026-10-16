import Darwin
import Foundation
import PadDomain

public struct FileProjectRepository: Sendable {
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
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try JSONDecoder().decode([Project].self, from: data)
    }

    public func saveProjects(_ projects: [Project]) throws {
        let data = try JSONEncoder().encode(projects)
        let temporaryDirectory = fileURL.deletingLastPathComponent()
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
