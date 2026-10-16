import Foundation
import PadDomain

public struct BlobHash: Hashable, Codable, Sendable {
    public enum ValidationError: Error {
        case invalidHash
    }

    public let value: String

    public init(_ value: String) throws {
        guard !value.isEmpty,
            value.allSatisfy({ character in
                character.isASCII && (character.isLetter || character.isNumber || character == "-")
            })
        else {
            throw ValidationError.invalidHash
        }

        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        do {
            try self.init(container.decode(String.self))
        } catch ValidationError.invalidHash {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid blob hash")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ReleaseManifestFile: Hashable, Codable, Sendable {
    public enum ValidationError: Error {
        case invalidPath
    }

    public let path: String
    public let blob: BlobHash

    public init(path: String, blob: BlobHash) throws {
        guard Self.isSafeRelativePath(path) else {
            throw ValidationError.invalidPath
        }
        self.path = path
        self.blob = blob
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let path = try container.decode(String.self, forKey: .path)
        let blob = try container.decode(BlobHash.self, forKey: .blob)
        do {
            try self.init(path: path, blob: blob)
        } catch ValidationError.invalidPath {
            throw DecodingError.dataCorruptedError(
                forKey: .path,
                in: container,
                debugDescription: "Invalid manifest file path"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(path, forKey: .path)
        try container.encode(blob, forKey: .blob)
    }

    private enum CodingKeys: String, CodingKey {
        case path
        case blob
    }

    private static let windowsDrivePrefixLength = 2

    private static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
            !path.hasPrefix("/"),
            !path.contains("\\"),
            !path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }

        if let first = components.first, Self.isWindowsDrivePath(first) {
            return false
        }
        return true
    }

    private static func isWindowsDrivePath(_ component: Substring) -> Bool {
        component.count == Self.windowsDrivePrefixLength && component.last == ":"
            && component.first?.isASCII == true && component.first?.isLetter == true
    }
}

public struct ReleaseManifest: Hashable, Codable, Sendable {
    public let files: [ReleaseManifestFile]

    public init(files: [ReleaseManifestFile]) {
        self.files = files
    }
}

public enum ProjectRunState: String, Codable, Hashable, Sendable {
    case running
    case stopped
}

public struct BlobBodyStream: HTTPBodyStream {
    private let iteratorFactory: @Sendable () -> @Sendable () async throws -> Data?

    public init(
        makePuller: @escaping @Sendable () -> @Sendable () async throws -> Data?
    ) {
        iteratorFactory = makePuller
    }

    public struct Iterator: AsyncIteratorProtocol, Sendable {
        private let puller: @Sendable () async throws -> Data?

        fileprivate init(puller: @escaping @Sendable () async throws -> Data?) {
            self.puller = puller
        }

        public mutating func next() async throws -> Data? {
            try await puller()
        }
    }

    public func makeAsyncIterator() -> Iterator {
        Iterator(puller: iteratorFactory())
    }
}

public protocol ProjectStorage: Sendable {
    func listProjects() async throws -> [Project]
    func saveProject(_ project: Project, routes: [Route]) async throws
    func projectRunState(for project: ProjectName) async throws -> ProjectRunState?
    func saveProjectRunState(_ state: ProjectRunState, for project: ProjectName) async throws
    func listRoutes() async throws -> [Route]
    func listReleases() async throws -> [Release]
    func releaseManifest(for releaseID: ReleaseID) async throws -> ReleaseManifest
    /// preparing 状態の release だけを保存し、active への切替は activateRelease に委ねます。
    func saveRelease(_ release: Release, manifest: ReleaseManifest) async throws
    /// 対象、project、manifest、全 blob を検証してから、旧 active の retired 化と新 active 化を原子的に行います。
    /// 検証に失敗した場合、同一 project の active 状態は変更しません。
    func activateRelease(_ releaseID: ReleaseID, for project: ProjectName) async throws
    func removeRelease(_ releaseID: ReleaseID) async throws
    func blobExists(_ hash: BlobHash) async throws -> Bool
    func saveBlob<Body: HTTPBodyStream>(_ hash: BlobHash, from body: Body) async throws
    /// 呼び出し側の next() ごとに最大 1 chunk を返し、需要前の先読みをしません。
    func openBlob(_ hash: BlobHash) async throws -> BlobBodyStream?
    func listBlobHashes() async throws -> [BlobHash]
    func removeBlob(_ hash: BlobHash) async throws
}
