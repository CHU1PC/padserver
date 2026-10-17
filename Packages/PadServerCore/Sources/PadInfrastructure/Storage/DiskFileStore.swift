import Darwin
import Foundation
import PadApplication
import PadDomain

public actor DiskFileStore: FileStore {
    public enum Failure: Error, Equatable {
        case invalidName
    }

    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func file(named name: String) throws -> StoredFile? {
        try Self.validate(name)
        guard let size = try regularFileSize(at: directory.appendingPathComponent(name)) else { return nil }
        return StoredFile(name: name, size: size)
    }

    public func listFiles() throws -> [StoredFile] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var files: [StoredFile] = []
        for url in urls {
            if let size = try regularFileSize(at: url) {
                files.append(StoredFile(name: url.lastPathComponent, size: size))
            }
        }
        return files.sorted { $0.name < $1.name }
    }

    public func saveFile<Body: HTTPBodyStream>(named name: String, from body: Body) async throws -> StoredFile {
        try Task.checkCancellation()
        try Self.validate(name)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".file-" + UUID().uuidString)
        let handle = try createTemporaryFile(at: temporary)
        do {
            let size = try await writeTemporaryFile(to: handle, from: body)
            try Task.checkCancellation()
            try renameTemporaryFile(temporary, to: directory.appendingPathComponent(name))
            return StoredFile(name: name, size: size)
        } catch {
            try removeFile(at: temporary)
            throw error
        }
    }

    public func openFile(named name: String) throws -> BlobBodyStream? {
        try Self.validate(name)
        let url = directory.appendingPathComponent(name)
        guard try regularFileSize(at: url) != nil else { return nil }
        return BlobBodyStream {
            let cursor = BlobFileCursor(url: url)
            return { try await cursor.next() }
        }
    }

    public func removeFile(named name: String) throws {
        try Self.validate(name)
        try removeFile(at: directory.appendingPathComponent(name))
    }

    private func regularFileSize(at url: URL) throws -> Int64? {
        var status = stat()
        guard Darwin.lstat(url.path, &status) == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return status.st_size
    }

    private func writeTemporaryFile<Body: HTTPBodyStream>(
        to handle: FileHandle, from body: Body
    ) async throws -> Int64 {
        var size: Int64 = 0
        do {
            for try await chunk in body {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                size += Int64(chunk.count)
            }
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
        return size
    }

    private func removeFile(at url: URL) throws {
        let result = Darwin.unlink(url.path)
        guard result == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func createTemporaryFile(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func renameTemporaryFile(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    // 先頭が "." の名前は、一時ファイルと見分けがつかず一覧にも出ないので拒みます。
    private static func validate(_ name: String) throws {
        guard !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\0") else {
            throw Failure.invalidName
        }
    }
}
