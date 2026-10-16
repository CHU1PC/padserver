public struct PlanDeployment {
    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func missingBlobs(from files: [ReleaseManifestFile]) async throws -> [ReleaseManifestFile] {
        var seenHashes: Set<BlobHash> = []
        var missingFiles: [ReleaseManifestFile] = []

        for file in files {
            guard seenHashes.insert(file.blob).inserted else { continue }
            if try await storage.blobExists(file.blob) == false {
                missingFiles.append(file)
            }
        }

        return missingFiles
    }
}
