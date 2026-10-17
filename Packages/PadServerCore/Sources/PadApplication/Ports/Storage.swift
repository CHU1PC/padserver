import Foundation
import PadDomain

public struct BlobHash: Hashable, Codable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self.init(try container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(value)
    }
}

public struct ReleaseManifestFile: Hashable, Codable, Sendable {
    public let path: String
    public let blob: BlobHash

    public init(path: String, blob: BlobHash) {
        self.path = path
        self.blob = blob
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
    /// host と prefix の重複検査と保存を原子的に行い、拒否時は既存の登録を変えません。
    func registerProject(_ project: Project, routes: [Route]) async throws
    func projectRunState(for project: ProjectName) async throws -> ProjectRunState?
    func saveProjectRunState(_ state: ProjectRunState, for project: ProjectName) async throws
    func listRoutes() async throws -> [Route]
    /// release を保存した順（古い順）で返します。
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
