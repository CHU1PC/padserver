import CryptoKit
import Darwin
import Foundation
import PadApplication
import PadDomain

public actor FileBlobStore {
    public enum Failure: Error, Equatable {
        case hashMismatch
    }

    // Issue #61 で SHA-256 の小文字16進64桁と決まりました。
    private static let hashCharacterCount = 64
    private let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    public func blobExists(_ hash: BlobHash) throws -> Bool {
        guard Self.isStoredHash(hash.value) else { return false }
        var status = stat()
        let result = Darwin.lstat(directory.appendingPathComponent(hash.value).path, &status)
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        return status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG)
    }

    public func blobSize(_ hash: BlobHash) throws -> Int64? {
        guard Self.isStoredHash(hash.value) else { return nil }
        var status = stat()
        let result = Darwin.lstat(directory.appendingPathComponent(hash.value).path, &status)
        guard result == 0 else {
            if errno == ENOENT || errno == ENOTDIR { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
        return status.st_size
    }

    public func saveBlob<Body: HTTPBodyStream>(_ hash: BlobHash, from body: Body) async throws {
        try Task.checkCancellation()
        guard Self.isStoredHash(hash.value) else { throw Failure.hashMismatch }
        if try blobExists(hash) { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(".blob-" + UUID().uuidString)
        let handle = try createTemporaryBlob(at: temporary)
        do {
            let digest = try await writeTemporaryBlob(to: handle, from: body)
            try Task.checkCancellation()
            let actual = digest.map { String(format: "%02x", $0) }.joined()
            guard actual == hash.value else { throw Failure.hashMismatch }
            try renameTemporaryBlob(temporary, to: directory.appendingPathComponent(actual))
        } catch {
            try removeFile(at: temporary)
            throw error
        }
    }

    public func openBlob(_ hash: BlobHash) throws -> BlobBodyStream? {
        guard try blobExists(hash) else { return nil }
        let url = directory.appendingPathComponent(hash.value)
        return BlobBodyStream {
            let cursor = BlobFileCursor(url: url)
            return { try await cursor.next() }
        }
    }

    public func listBlobHashes() throws -> [BlobHash] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
        var hashes: [BlobHash] = []
        for url in urls where Self.isStoredHash(url.lastPathComponent) {
            let hash = try BlobHash(url.lastPathComponent)
            if try blobExists(hash) { hashes.append(hash) }
        }
        return hashes.sorted { $0.value < $1.value }
    }

    public func removeBlob(_ hash: BlobHash) throws {
        guard try blobExists(hash) else { return }
        try removeFile(at: directory.appendingPathComponent(hash.value))
    }

    private func writeTemporaryBlob<Body: HTTPBodyStream>(
        to handle: FileHandle, from body: Body
    ) async throws -> CryptoKit.SHA256.Digest {
        var hasher = CryptoKit.SHA256()
        do {
            for try await chunk in body {
                try Task.checkCancellation()
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
            }
        } catch {
            try handle.close()
            throw error
        }
        try handle.close()
        return hasher.finalize()
    }

    private func removeFile(at url: URL) throws {
        let result = Darwin.unlink(url.path)
        guard result == 0 || errno == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private func createTemporaryBlob(at url: URL) throws -> FileHandle {
        let descriptor = Darwin.open(
            url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    private func renameTemporaryBlob(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { destinationPath in
                Darwin.rename(sourcePath, destinationPath)
            }
        }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func isStoredHash(_ value: String) -> Bool {
        value.utf8.count == hashCharacterCount
            && value.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
    }
}

private actor BlobFileCursor {
    // 読み出しを1 pull あたり64 KiBに分け、blob 全体をメモリへ積みません。
    private static let chunkByteCount = 65_536
    private let url: URL
    private var handle: FileHandle?
    private var finished = false

    init(url: URL) { self.url = url }

    func next() throws -> Data? {
        guard !finished else { return nil }
        if Task.isCancelled {
            try finish()
            throw CancellationError()
        }
        let reader = try handle ?? openReader()
        handle = reader
        let data: Data?
        do {
            data = try reader.read(upToCount: Self.chunkByteCount)
        } catch {
            try finish()
            throw error
        }
        guard let data, !data.isEmpty else {
            try finish()
            return nil
        }
        return data
    }

    private func openReader() throws -> FileHandle {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var status = stat()
        guard Darwin.fstat(descriptor, &status) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try reader.close()
            throw error
        }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else {
            try reader.close()
            throw POSIXError(.EINVAL)
        }
        return reader
    }

    private func finish() throws {
        finished = true
        let reader = handle
        handle = nil
        try reader?.close()
    }
}
