import PadDomain

public struct CommitDeployment: Sendable {
    public enum Failure: Error, Equatable {
        case blobNotFound(BlobHash)
    }

    private let storage: any ProjectStorage
    private let idGenerator: any IDGenerator

    public init(storage: any ProjectStorage, idGenerator: any IDGenerator) {
        self.storage = storage
        self.idGenerator = idGenerator
    }

    public func callAsFunction(project: ProjectName, manifest: ReleaseManifest) async throws -> Release {
        for file in manifest.files {
            guard try await storage.blobExists(file.blob) else {
                throw Failure.blobNotFound(file.blob)
            }
        }

        let releaseID = ReleaseID(idGenerator.generate())
        let preparingRelease = Release(id: releaseID, project: project, state: .preparing)
        try await storage.saveRelease(preparingRelease, manifest: manifest)
        try await storage.activateRelease(releaseID, for: project)

        return Release(id: releaseID, project: project, state: .active)
    }
}
