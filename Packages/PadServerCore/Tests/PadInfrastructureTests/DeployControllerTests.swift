import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import PadTestSupport
import Testing

private enum DeployControllerTestConstants {
    static let releaseID = UUID(uuidString: "00000000-0000-4000-8000-000000000001") ?? UUID()
    static let storedHash = "stored-hash"
    static let newHash = "new-hash"
}

private struct DeployControllerFixture {
    let storage = InMemoryProjectStorage()
    let application: Application<RouterResponder<AdminRequestContext>>

    init() {
        let router = Router(context: AdminRequestContext.self)
        DeployController(
            planDeployment: PlanDeployment(storage: storage),
            commitDeployment: CommitDeployment(
                storage: storage,
                idGenerator: FixedIDGenerator(id: DeployControllerTestConstants.releaseID))
        ).addRoutes(to: router)
        application = Application(responder: router.buildResponder())
    }

    func storeBlob(_ hash: String) async throws {
        try await storage.saveBlob(BlobHash(hash), from: BlobBodyStream { { nil } })
    }

    func registerProject(_ name: String) async throws {
        let projectName = try ProjectName(name)
        try await storage.saveProject(Project(name: projectName, kind: .staticSite), routes: [])
    }
}

private func deploymentBody(name: String = "example-site", hashes: [String]) -> ByteBuffer {
    let files = hashes.enumerated().map { #"{"path":"file\#($0.offset).html","hash":"\#($0.element)"}"# }
    let json = """
        {"manifest":{"name":"\(name)","root":"dist","routes":[{"host":"www.example.com","path_prefix":"/"}]},\
        "files":[\(files.joined(separator: ","))]}
        """
    return ByteBuffer(string: json)
}

private func errorCode(_ response: TestResponse) throws -> AdminErrorCode {
    try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: Data(response.body.readableBytesView))
        .error.code
}

@Test func diffReturnsOnlyBlobsMissingFromStorage() async throws {
    let fixture = DeployControllerFixture()
    try await fixture.storeBlob(DeployControllerTestConstants.storedHash)

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/projects/example-site/deployments/diff",
            method: .post,
            body: deploymentBody(hashes: [
                DeployControllerTestConstants.storedHash,
                DeployControllerTestConstants.newHash,
            ])
        )

        #expect(response.status == .ok)
        let body = try AdminAPIJSON.makeDecoder().decode(
            AdminDeploymentDiffResponse.self, from: Data(response.body.readableBytesView))
        #expect(
            body.missingBlobs == [
                AdminDeploymentFile(path: "file1.html", hash: BlobHash(DeployControllerTestConstants.newHash))
            ])
    }
}

@Test func diffReturnsEmptyListWhenAllBlobsExist() async throws {
    let fixture = DeployControllerFixture()
    try await fixture.storeBlob(DeployControllerTestConstants.storedHash)

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/projects/example-site/deployments/diff",
            method: .post,
            body: deploymentBody(hashes: [DeployControllerTestConstants.storedHash])
        )

        #expect(response.status == .ok)
        let body = try AdminAPIJSON.makeDecoder().decode(
            AdminDeploymentDiffResponse.self, from: Data(response.body.readableBytesView))
        #expect(body.missingBlobs.isEmpty)
    }
}

@Test func commitCreatesActiveReleaseWhenAllBlobsExist() async throws {
    let fixture = DeployControllerFixture()
    try await fixture.registerProject("example-site")
    try await fixture.storeBlob(DeployControllerTestConstants.storedHash)

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/projects/example-site/deployments",
            method: .post,
            body: deploymentBody(hashes: [DeployControllerTestConstants.storedHash])
        )

        #expect(response.status == .created)
        let body = try AdminAPIJSON.makeDecoder().decode(
            AdminDeploymentResponse.self, from: Data(response.body.readableBytesView))
        let name = try ProjectName("example-site")
        #expect(body.project == Project(name: name, kind: .staticSite))
        #expect(
            body.release
                == Release(id: ReleaseID(DeployControllerTestConstants.releaseID), project: name, state: .active))
    }
    #expect(try await fixture.storage.listReleases().map(\.state) == [.active])
}

@Test func commitRejectsMissingBlobWithConflictAndKeepsReleases() async throws {
    let fixture = DeployControllerFixture()
    try await fixture.registerProject("example-site")

    try await fixture.application.test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/projects/example-site/deployments",
            method: .post,
            body: deploymentBody(hashes: [DeployControllerTestConstants.newHash])
        )

        #expect(response.status == .conflict)
        #expect(try errorCode(response) == .deploymentIncomplete)
    }
    #expect(try await fixture.storage.listReleases().isEmpty)
}

@Test(arguments: ["diff", ""])
func deploymentEndpointsRejectInvalidInput(suffix: String) async throws {
    let fixture = DeployControllerFixture()
    let base = "/v1/projects/example-site/deployments"
    let uri = suffix.isEmpty ? base : "\(base)/\(suffix)"
    let invalidBodies = [
        ByteBuffer(string: "not json"),
        ByteBuffer(string: #"{"manifest":{"name":"example-site","root":"/abs","routes":[]},"files":[]}"#),
        deploymentBody(name: "other-site", hashes: []),
    ]

    try await fixture.application.test(.router) { client in
        for body in invalidBodies {
            let response = try await client.execute(uri: uri, method: .post, body: body)
            #expect(response.status == .badRequest)
            #expect(try errorCode(response) == .invalidRequest)
        }

        let badName = try await client.execute(
            uri: uri.replacingOccurrences(of: "example-site", with: "Bad_Name"),
            method: .post,
            body: deploymentBody(name: "example-site", hashes: [])
        )
        #expect(badName.status == .badRequest)
        #expect(try errorCode(badName) == .invalidRequest)
    }
}

@Test(arguments: ["/v1/projects/example-site/deployments/diff", "/v1/projects/example-site/deployments"])
func deploymentEndpointsRequireAdminAuthorization(uri: String) async throws {
    let fixture = DeployControllerFixture()
    let application = try AdminServer.makeApplication(
        adminPort: 8081,
        deliveryPort: 8080,
        tailnetAddress: "100.64.0.1",
        authorizeAdmin: AuthorizeAdmin(secretStore: InMemorySecretStore())
    ) { router in
        DeployController(
            planDeployment: PlanDeployment(storage: fixture.storage),
            commitDeployment: CommitDeployment(
                storage: fixture.storage, idGenerator: FixedIDGenerator(id: DeployControllerTestConstants.releaseID))
        ).addRoutes(to: router)
    }

    try await application.test(.router) { client in
        let response = try await client.execute(uri: uri, method: .post, body: deploymentBody(hashes: []))
        #expect(response.status == .unauthorized)
    }
}
