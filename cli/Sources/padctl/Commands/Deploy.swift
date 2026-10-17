import ArgumentParser
import Foundation
import PadApplication
import PadDomain
import PadInterface

struct DeployReport: Equatable {
    let fileCount: Int
    let uploadedCount: Int
    let project: ProjectName
    let release: Release
}

struct DeployService {
    private let client: AdminClient

    init(client: AdminClient) {
        self.client = client
    }

    func deploy(manifest: ProjectManifest, baseDirectory: URL) async throws -> DeployReport {
        let root = baseDirectory.appending(path: manifest.root, directoryHint: .isDirectory)
        let files = try StaticSiteScanner.scan(root: root)
        let request = AdminDeploymentRequest(
            manifest: manifest,
            files: files.map { AdminDeploymentFile(path: $0.path, hash: $0.hash) }
        )

        let diff = try await client.diffDeployment(project: manifest.name, request: request)
        let missingHashes = Set(diff.missingBlobs.map(\.hash))
        var uploaded = Set<BlobHash>()
        for file in files where missingHashes.contains(file.hash) && uploaded.insert(file.hash).inserted {
            try await client.uploadBlob(hash: file.hash, file: file.url)
        }

        let response = try await client.commitDeployment(project: manifest.name, request: request)
        return DeployReport(
            fileCount: files.count,
            uploadedCount: uploaded.count,
            project: response.project.name,
            release: response.release
        )
    }
}

struct Deploy: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Deploy a static site to the server."
    )

    @Option(help: "Path to the project manifest. The site root is resolved from its directory.")
    var manifest = "padserver.toml"

    mutating func run() async throws {
        let manifestURL = URL(filePath: manifest)
        let source = try String(contentsOf: manifestURL, encoding: .utf8)
        let client = try AdminClient(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            tokenStore: KeychainTokenStore()
        )
        let report = try await DeployService(client: client).deploy(
            manifest: try ManifestLoader.load(from: source),
            baseDirectory: manifestURL.deletingLastPathComponent()
        )
        print(
            "Deployed \(report.project.value): \(report.fileCount) files, \(report.uploadedCount) uploaded. "
                + "Release \(report.release.id.value) is \(report.release.state.rawValue)."
        )
    }
}
