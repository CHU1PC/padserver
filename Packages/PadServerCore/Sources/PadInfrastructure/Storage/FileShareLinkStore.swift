import Foundation
import PadApplication

public actor FileShareLinkStore: ShareLinkStore {
    private let fileURL: URL
    private let writeData: @Sendable (Data, URL) throws -> Void

    public init(directory: URL) {
        self.init(
            directory: directory,
            writeData: { data, url in
                try data.write(to: url, options: .atomic)
            })
    }

    init(directory: URL, writeData: @escaping @Sendable (Data, URL) throws -> Void) {
        fileURL = directory.appendingPathComponent("share-links.json")
        self.writeData = writeData
    }

    public func saveLink(_ record: StoredShareLink) throws {
        var records = try readRecords()
        records.removeAll { $0.link.id == record.link.id }
        records.append(record)
        try saveRecords(records)
    }

    public func link(forSecretHash secretHash: String) throws -> StoredShareLink? {
        try readRecords().first { $0.secretHash == secretHash }
    }

    public func listLinks(forFileNamed name: String) throws -> [StoredShareLink] {
        try readRecords().filter { $0.fileName == name }
    }

    public func removeLink(id: UUID) throws {
        let records = try readRecords()
        let remaining = records.filter { $0.link.id != id }
        guard remaining.count != records.count else { return }
        try saveRecords(remaining)
    }

    public func removeLinks(forFileNamed name: String) throws {
        let records = try readRecords()
        let remaining = records.filter { $0.fileName != name }
        guard remaining.count != records.count else { return }
        try saveRecords(remaining)
    }

    private func readRecords() throws -> [StoredShareLink] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return []
        }
        return try JSONDecoder().decode([StoredShareLink].self, from: data)
    }

    private func saveRecords(_ records: [StoredShareLink]) throws {
        let data = try JSONEncoder().encode(records)
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try writeData(data, fileURL)
    }
}
