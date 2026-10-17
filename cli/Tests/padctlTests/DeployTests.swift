import Foundation
import PadApplication
import PadDomain
import PadInterface
import Synchronization
import Testing
@testable import padctl

private let helloHash = "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
private let worldHash = "486ea46224d1bb4fb680f34f7c9ad96a8f24ec88be73ea8e5a6c65260e9cb8a7"

private let okStatus = 200
private let createdStatus = 201

private let commitBody = """
    {"project":{"name":"example-site","kind":"staticSite"},
     "release":{"id":"00000000-0000-4000-8000-000000000001","project":"example-site","state":"active"}}
    """

private struct DeployFixture {
    let directory: URL
    let manifest: ProjectManifest

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "padctl-deploy-\(UUID().uuidString)")
        let site = directory.appending(path: "dist")
        try FileManager.default.createDirectory(
            at: site.appending(path: "sub"), withIntermediateDirectories: true)
        try Data("hello".utf8).write(to: site.appending(path: "a.txt"))
        try Data("hello".utf8).write(to: site.appending(path: "sub/b.txt"))
        try Data("world".utf8).write(to: site.appending(path: "c.txt"))
        manifest = try ManifestLoader.load(
            from: """
                name = "example-site"
                root = "dist"

                [[routes]]
                host = "example.com"
                path_prefix = "/"
                """)
    }

    func remove() {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the fixture directory: \(error)")
        }
    }
}

private func makeStubClient(
    diffBody: String,
    log: DeployRequestLog
) throws -> (client: AdminClient, host: String) {
    let host = "stub-\(UUID().uuidString.lowercased()).example.com"
    StubURLProtocol.register(host: host) { request in
        log.append(request)
        if request.path.hasSuffix("/deployments/diff") {
            return .json(status: okStatus, body: diffBody)
        }
        if request.path.hasPrefix("/v1/blobs/") {
            return .json(status: createdStatus, body: "{}")
        }
        return .json(status: createdStatus, body: commitBody)
    }
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    let client = try AdminClient(
        configStore: StubServerConfigStore(config: PadctlConfig(serverURL: #require(URL(string: "https://\(host)")))),
        tokenStore: StubServerTokenStore(token: "dummy-token"),
        session: URLSession(configuration: configuration)
    )
    return (client, host)
}

private final class DeployRequestLog: Sendable {
    private let storage = Mutex<[CapturedRequest]>([])

    var requests: [CapturedRequest] {
        storage.withLock { $0 }
    }

    func append(_ request: CapturedRequest) {
        storage.withLock { $0.append(request) }
    }
}

@Test func deployCommandIsRegistered() throws {
    #expect(try Padctl.parseAsRoot(["deploy"]) is Deploy)
}

@Test func scannerReturnsRelativePathsWithSha256() throws {
    let fixture = try DeployFixture()
    defer { fixture.remove() }

    let files = try StaticSiteScanner.scan(root: fixture.directory.appending(path: "dist"))

    #expect(files.map(\.path) == ["a.txt", "c.txt", "sub/b.txt"])
    #expect(files.map(\.hash.value) == [helloHash, worldHash, helloHash])
}

@Test func scannerRejectsMissingRoot() throws {
    let fixture = try DeployFixture()
    defer { fixture.remove() }

    #expect(throws: StaticSiteScannerError.rootNotFound("missing")) {
        try StaticSiteScanner.scan(root: fixture.directory.appending(path: "missing"))
    }
}

@Test func deployUploadsOnlyMissingBlobsOnce() async throws {
    let fixture = try DeployFixture()
    defer { fixture.remove() }
    let log = DeployRequestLog()
    let (client, host) = try makeStubClient(
        diffBody: #"{"missingBlobs":[{"path":"c.txt","hash":"\#(worldHash)"}]}"#, log: log)
    defer { StubURLProtocol.unregister(host: host) }

    let report = try await DeployService(client: client).deploy(
        manifest: fixture.manifest, baseDirectory: fixture.directory)

    #expect(report.fileCount == 3)
    #expect(report.uploadedCount == 1)
    let sent = log.requests.map { "\($0.method) \($0.path)" }
    #expect(
        sent == [
            "POST /v1/projects/example-site/deployments/diff",
            "PUT /v1/blobs/\(worldHash)",
            "POST /v1/projects/example-site/deployments",
        ])
    let body = try JSONDecoder().decode(AdminDeploymentRequest.self, from: log.requests[0].body)
    #expect(body.files.map(\.path) == ["a.txt", "c.txt", "sub/b.txt"])
}

@Test func secondDeployWithNoChangesSendsNoFiles() async throws {
    let fixture = try DeployFixture()
    defer { fixture.remove() }
    let log = DeployRequestLog()
    let (client, host) = try makeStubClient(diffBody: #"{"missingBlobs":[]}"#, log: log)
    defer { StubURLProtocol.unregister(host: host) }

    let report = try await DeployService(client: client).deploy(
        manifest: fixture.manifest, baseDirectory: fixture.directory)

    #expect(report.uploadedCount == 0)
    #expect(!log.requests.contains { $0.method == "PUT" })
    #expect(log.requests.last?.path == "/v1/projects/example-site/deployments")
}
