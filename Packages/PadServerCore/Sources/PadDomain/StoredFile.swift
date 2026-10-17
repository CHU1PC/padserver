public struct StoredFile: Codable, Hashable, Sendable {
    public let name: String
    public let size: Int64

    public init(name: String, size: Int64) {
        self.name = name
        self.size = size
    }
}
