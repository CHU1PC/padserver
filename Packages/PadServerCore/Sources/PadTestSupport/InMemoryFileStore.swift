import Foundation
import PadApplication
import PadDomain

public actor InMemoryFileStore: FileStore {
    private var files: [String: [Data]] = [:]

    public init() {
        // 明示した初期化子で公開 API を安定させます。
    }

    public func file(named name: String) throws -> StoredFile? {
        files[name].map { StoredFile(name: name, size: Self.size(of: $0)) }
    }

    public func listFiles() throws -> [StoredFile] {
        files.keys.sorted().compactMap { name in
            files[name].map { StoredFile(name: name, size: Self.size(of: $0)) }
        }
    }

    public func saveFile<Body: HTTPBodyStream>(named name: String, from body: Body) async throws -> StoredFile {
        var chunks: [Data] = []
        for try await chunk in body {
            chunks.append(chunk)
        }
        files[name] = chunks
        return StoredFile(name: name, size: Self.size(of: chunks))
    }

    public func openFile(named name: String) throws -> BlobBodyStream? {
        guard let chunks = files[name] else { return nil }
        return BlobBodyStream {
            let cursor = FileChunkCursor(chunks: chunks)
            return { await cursor.next() }
        }
    }

    public func removeFile(named name: String) throws {
        files[name] = nil
    }

    private static func size(of chunks: [Data]) -> Int64 {
        chunks.reduce(0) { $0 + Int64($1.count) }
    }
}

private actor FileChunkCursor {
    private let chunks: [Data]
    private var index = 0

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func next() -> Data? {
        guard index < chunks.count else { return nil }
        defer { index += 1 }
        return chunks[index]
    }
}
