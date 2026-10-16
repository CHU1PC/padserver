import PadDomain

public struct PruneReleases: Sendable {
    // Issue #54 の保持数は、プロジェクトごとに直近3件です。
    private static let retainedReleaseCount = 3
    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func callAsFunction() async throws {
        let releases = try await storage.listReleases()
        var counts: [ProjectName: Int] = [:]
        var retainedIDs: Set<ReleaseID> = []
        for release in releases.reversed() {
            let count = counts[release.project, default: 0]
            if count < Self.retainedReleaseCount || release.state == .active {
                retainedIDs.insert(release.id)
            }
            counts[release.project] = count + 1
        }
        var referencedHashes: Set<BlobHash> = []
        for release in releases where retainedIDs.contains(release.id) {
            let manifest = try await storage.releaseManifest(for: release.id)
            referencedHashes.formUnion(manifest.files.map(\.blob))
        }
        let blobHashes = try await storage.listBlobHashes()
        for release in releases where !retainedIDs.contains(release.id) {
            try await storage.removeRelease(release.id)
        }
        for hash in blobHashes where !referencedHashes.contains(hash) {
            try await storage.removeBlob(hash)
        }
    }
}
