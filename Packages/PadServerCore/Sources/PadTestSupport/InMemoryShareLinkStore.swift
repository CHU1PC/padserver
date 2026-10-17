import Foundation
import PadApplication

public actor InMemoryShareLinkStore: ShareLinkStore {
    private var records: [UUID: StoredShareLink] = [:]

    public init() {
        // 明示した初期化子で公開 API を安定させます。
    }

    public func saveLink(_ record: StoredShareLink) throws {
        records[record.link.id] = record
    }

    public func link(forSecretHash secretHash: String) throws -> StoredShareLink? {
        records.values.first { $0.secretHash == secretHash }
    }

    public func listLinks(forFileNamed name: String) throws -> [StoredShareLink] {
        records.values.filter { $0.fileName == name }.sorted { $0.link.expiresAt < $1.link.expiresAt }
    }

    public func removeLink(id: UUID) throws {
        records[id] = nil
    }

    public func removeLinks(forFileNamed name: String) throws {
        records = records.filter { $0.value.fileName != name }
    }
}
