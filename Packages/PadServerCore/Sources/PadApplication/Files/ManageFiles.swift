import PadDomain

public struct ManageFiles: Sendable {
    private let fileStore: any FileStore
    private let linkStore: any ShareLinkStore

    public init(fileStore: any FileStore, linkStore: any ShareLinkStore) {
        self.fileStore = fileStore
        self.linkStore = linkStore
    }

    public func list() async throws -> [StoredFile] {
        try await fileStore.listFiles()
    }

    /// 共有リンクを先に失効させてからファイルを消します。存在しない名前でも成功します。
    public func delete(named name: String) async throws {
        try await linkStore.removeLinks(forFileNamed: name)
        try await fileStore.removeFile(named: name)
    }
}
