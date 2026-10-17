import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
@testable import PadInfrastructure
import PadTestSupport
import Testing

private enum PadServersTestConstants {
    static let deliveryPort = 8080
    static let adminPort = 8081
    static let tailnetAddress = "100.64.0.1"
    static let blobHashText = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
}

private func makeServers(
    storage: InMemoryProjectStorage = InMemoryProjectStorage(),
    adminPort: Int = PadServersTestConstants.adminPort
) -> PadServers {
    PadServers(
        ports: PadServerPorts(
            delivery: PadServersTestConstants.deliveryPort, admin: adminPort,
            tailnetAddress: PadServersTestConstants.tailnetAddress),
        storage: storage,
        secretStore: InMemorySecretStore(),
        idGenerator: FixedIDGenerator(id: UUID()),
        logBus: PadTestSupport.InMemoryLogBus())
}

private actor OneShotCursor {
    private var data: Data?

    init(_ data: Data) { self.data = data }

    func next() -> Data? {
        defer { data = nil }
        return data
    }
}

private func seedRoute(storage: InMemoryProjectStorage, target: RouteTarget) async throws {
    let route = Route(
        project: try ProjectName("site"), host: try RouteHost("localhost"),
        pathPrefix: try RoutePathPrefix("/"), target: target)
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let hash = try BlobHash(PadServersTestConstants.blobHashText)
    try await storage.saveBlob(
        hash,
        from: BlobBodyStream {
            let cursor = OneShotCursor(Data("hello".utf8))
            return { await cursor.next() }
        })
    let release = Release(id: ReleaseID(UUID()), project: route.project, state: .preparing)
    let manifest = ReleaseManifest(files: [try .init(path: "index.html", blob: hash)])
    try await storage.saveRelease(release, manifest: manifest)
    try await storage.activateRelease(release.id, for: route.project)
}

@Test func padServersServeStaticSiteOnDeliveryApplication() async throws {
    let storage = InMemoryProjectStorage()
    try await seedRoute(storage: storage, target: .staticSite)

    try await makeServers(storage: storage).makeDeliveryApplication().test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get)
        #expect(response.status == .ok)
        #expect(String(buffer: response.body) == "hello")
    }
}

@Test func padServersAnswerBadGatewayForContainerRoutes() async throws {
    let storage = InMemoryProjectStorage()
    try await seedRoute(storage: storage, target: .container(try ContainerRouteTarget(service: "web", port: 80)))

    try await makeServers(storage: storage).makeDeliveryApplication().test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get)
        #expect(response.status == .badGateway)
    }
}

@Test func padServersRejectUnauthenticatedAdminRequests() async throws {
    try await makeServers().makeAdminApplication().test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects", method: .get)
        #expect(response.status == .unauthorized)
    }
}

@Test func padServersRejectEqualPorts() {
    #expect(throws: AdminServerError.portsMustBeDistinct) {
        try makeServers(adminPort: PadServersTestConstants.deliveryPort).makeAdminApplication()
    }
}
