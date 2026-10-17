import PadDomain

public struct StoreFile: Sendable {
    public enum Error: Swift.Error, Equatable, Sendable {
        case invalidName
    }

    private let store: any FileStore

    public init(store: any FileStore) {
        self.store = store
    }

    /// 名前を検証してから保存します。同じ名前のファイルは置き換わります。
    public func save<Body: HTTPBodyStream>(named name: String, from body: Body) async throws -> StoredFile {
        try Self.validate(name)
        return try await store.saveFile(named: name, from: body)
    }

    /// 存在しないファイルは nil を返します。
    public func open(named name: String) async throws -> BlobBodyStream? {
        try Self.validate(name)
        return try await store.openFile(named: name)
    }

    private static func validate(_ name: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw Error.invalidName
        }
    }
}
