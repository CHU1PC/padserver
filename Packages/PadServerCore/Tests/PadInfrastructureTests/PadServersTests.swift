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
    static let now = Date(timeIntervalSinceReferenceDate: 0)
    static let validity: TimeInterval = 3600
    static let fileName = "report.txt"
    static let fileContent = "shared"
    static let expiresAtText = "2001-01-01T01:00:00Z"
}

private func makeServers(
    storage: InMemoryProjectStorage = InMemoryProjectStorage(),
    adminPort: Int = PadServersTestConstants.adminPort,
    fileStore: InMemoryFileStore = InMemoryFileStore(),
    linkStore: InMemoryShareLinkStore = InMemoryShareLinkStore(),
    now: Date = PadServersTestConstants.now
) -> PadServers {
    PadServers(
        ports: PadServerPorts(
            delivery: PadServersTestConstants.deliveryPort, admin: adminPort,
            tailnetAddress: PadServersTestConstants.tailnetAddress),
        storage: storage,
        secretStore: InMemorySecretStore(),
        idGenerator: FixedIDGenerator(id: UUID()),
        logBus: PadTestSupport.InMemoryLogBus(),
        fileStore: fileStore,
        linkStore: linkStore,
        timeSource: FixedTimeSource(timestamp: now))
}

private func seedFile(_ fileStore: InMemoryFileStore) async throws {
    _ = try await fileStore.saveFile(
        named: PadServersTestConstants.fileName,
        from: BlobBodyStream {
            let cursor = OneShotCursor(Data(PadServersTestConstants.fileContent.utf8))
            return { await cursor.next() }
        })
}

private func issueLink(
    fileStore: InMemoryFileStore, linkStore: InMemoryShareLinkStore
) async throws -> IssuedShareLink {
    try await seedFile(fileStore)
    return try await ShareLinks(
        fileStore: fileStore, linkStore: linkStore,
        timeSource: FixedTimeSource(timestamp: PadServersTestConstants.now),
        idGenerator: FixedIDGenerator(id: UUID())
    ).issue(fileName: PadServersTestConstants.fileName, validFor: PadServersTestConstants.validity)
}

private func adminRouterApplication(_ servers: PadServers) -> Application<RouterResponder<AdminRequestContext>> {
    let router = Router(context: AdminRequestContext.self)
    servers.addAdminRoutes(to: router)
    return Application(responder: router.buildResponder())
}

struct AdminRouteCase: Sendable {
    let method: HTTPRequest.Method
    let path: String
    let body: String?
}

private let adminFileRouteCases = [
    AdminRouteCase(method: .put, path: "/v1/files/a.txt", body: "x"),
    AdminRouteCase(method: .get, path: "/v1/files/a.txt", body: nil),
    AdminRouteCase(method: .get, path: "/v1/files", body: nil),
    AdminRouteCase(method: .delete, path: "/v1/files/a.txt", body: nil),
    AdminRouteCase(
        method: .post, path: "/v1/files/a.txt/share-links",
        body: "{\"expiresAt\":\"\(PadServersTestConstants.expiresAtText)\"}"),
    AdminRouteCase(method: .get, path: "/v1/share-links", body: nil),
    AdminRouteCase(method: .delete, path: "/v1/share-links/00000000-0000-4000-8000-000000000002", body: nil),
]

@Test func padServersAdminRoutesServeFilesAndShareLinks() async throws {
    try await adminRouterApplication(makeServers()).test(.router) { client in
        func execute(_ method: HTTPRequest.Method, _ path: String, body: String? = nil) async throws -> TestResponse {
            try await client.execute(
                uri: path, method: method, body: body.map { ByteBuffer(string: $0) })
        }
        let put = try await execute(.put, "/v1/files/a.txt", body: "hello")
        #expect(put.status == .created)
        let get = try await execute(.get, "/v1/files/a.txt")
        #expect(get.status == .ok)
        #expect(String(buffer: get.body) == "hello")
        let list = try await execute(.get, "/v1/files")
        #expect(list.status == .ok)
        let issue = try await execute(
            .post, "/v1/files/a.txt/share-links",
            body: "{\"expiresAt\":\"\(PadServersTestConstants.expiresAtText)\"}")
        #expect(issue.status == .created)
        let links = try await execute(.get, "/v1/share-links")
        #expect(links.status == .ok)
        #expect(String(buffer: links.body).contains("a.txt"))
        let revokeUnknown = try await execute(.delete, "/v1/share-links/00000000-0000-4000-8000-000000000002")
        #expect(revokeUnknown.status == .notFound)
        let delete = try await execute(.delete, "/v1/files/a.txt")
        #expect(delete.status == .noContent)
    }
}

@Test(arguments: adminFileRouteCases)
func padServersRejectUnauthenticatedFileAndShareLinkRequests(routeCase: AdminRouteCase) async throws {
    try await makeServers().makeAdminApplication().test(.router) { client in
        let response = try await client.execute(
            uri: routeCase.path, method: routeCase.method, body: routeCase.body.map { ByteBuffer(string: $0) })
        #expect(response.status == .unauthorized)
    }
}

@Test func padServersAdminRoutesDoNotServeShareLinkReads() async throws {
    let fileStore = InMemoryFileStore()
    let linkStore = InMemoryShareLinkStore()
    let issued = try await issueLink(fileStore: fileStore, linkStore: linkStore)

    try await adminRouterApplication(makeServers(fileStore: fileStore, linkStore: linkStore)).test(.router) { client in
        let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(response.status == .notFound)
    }
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

private typealias DeliveryApplication = Application<CallbackResponder<BasicRequestContext>>

private let deliveryApplicationMakers: [(String, @Sendable (PadServers) -> DeliveryApplication)] = [
    ("loopback", { $0.makeDeliveryApplication() }),
    ("tailnet", { $0.makeTailnetDeliveryApplication() }),
]

@Test(arguments: deliveryApplicationMakers.map(\.0))
func padServersAnswerTheSameOnLoopbackAndTailnetDelivery(name: String) async throws {
    let makeApplication = try #require(deliveryApplicationMakers.first { $0.0 == name }).1
    let storage = InMemoryProjectStorage()
    try await seedRoute(storage: storage, target: .staticSite)

    try await makeApplication(makeServers(storage: storage)).test(.router) { client in
        let site = try await client.execute(uri: "/", method: .get)
        #expect(site.status == .ok)
        #expect(String(buffer: site.body) == "hello")
    }
    try await makeApplication(makeServers()).test(.router) { client in
        let unrouted = try await client.execute(uri: "/", method: .get)
        #expect(unrouted.status == .notFound)

        for path in ["/v1/projects", "/v1/files", "/v1/share-links"] {
            let admin = try await client.execute(uri: path, method: .get)
            #expect(admin.status == .notFound)
        }
    }
}

@Test(arguments: deliveryApplicationMakers.map(\.0))
func padServersServeShareLinksOnDelivery(name: String) async throws {
    let makeApplication = try #require(deliveryApplicationMakers.first { $0.0 == name }).1
    let fileStore = InMemoryFileStore()
    let linkStore = InMemoryShareLinkStore()
    let issued = try await issueLink(fileStore: fileStore, linkStore: linkStore)

    try await makeApplication(makeServers(fileStore: fileStore, linkStore: linkStore)).test(.router) { client in
        let served = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(served.status == .ok)
        #expect(String(buffer: served.body) == PadServersTestConstants.fileContent)

        let unknown = try await client.execute(uri: "/s/unknown-secret", method: .get)
        #expect(unknown.status == .notFound)
        let empty = try await client.execute(uri: "/s/", method: .get)
        #expect(empty.status == .notFound)

        try await ShareLinks(
            fileStore: fileStore, linkStore: linkStore,
            timeSource: FixedTimeSource(timestamp: PadServersTestConstants.now),
            idGenerator: FixedIDGenerator(id: UUID())
        ).revoke(id: issued.link.id)
        let revoked = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        #expect(revoked.status == .notFound)
    }
}

@Test func padServersAnswerNotFoundForExpiredShareLink() async throws {
    let fileStore = InMemoryFileStore()
    let linkStore = InMemoryShareLinkStore()
    let issued = try await issueLink(fileStore: fileStore, linkStore: linkStore)
    let expired = PadServersTestConstants.now.addingTimeInterval(PadServersTestConstants.validity + 1)

    try await makeServers(fileStore: fileStore, linkStore: linkStore, now: expired).makeDeliveryApplication()
        .test(.router) { client in
            let response = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
            #expect(response.status == .notFound)
        }
}

@Test func padServersKeepShareLinkSecretsOutOfRequestLogs() async throws {
    let fileStore = InMemoryFileStore()
    let linkStore = InMemoryShareLinkStore()
    let issued = try await issueLink(fileStore: fileStore, linkStore: linkStore)
    let logBus = PadTestSupport.InMemoryLogBus()
    let servers = PadServers(
        ports: PadServerPorts(
            delivery: PadServersTestConstants.deliveryPort, admin: PadServersTestConstants.adminPort,
            tailnetAddress: PadServersTestConstants.tailnetAddress),
        storage: InMemoryProjectStorage(), secretStore: InMemorySecretStore(),
        idGenerator: FixedIDGenerator(id: UUID()), logBus: logBus,
        fileStore: fileStore, linkStore: linkStore,
        timeSource: FixedTimeSource(timestamp: PadServersTestConstants.now))

    try await servers.makeDeliveryApplication().test(.router) { client in
        _ = try await client.execute(uri: "/s/\(issued.secret)", method: .get)
        _ = try await client.execute(uri: "/", method: .get)
    }
    var iterator = await logBus.subscribe().makeAsyncIterator()
    let entry = await iterator.next()
    #expect(entry?.message.contains(issued.secret) == false)
}

@Test func padServersListenOnLoopbackAndTailnetWithTheDeliveryPort() {
    let servers = makeServers()
    #expect(
        servers.makeDeliveryApplication().configuration.address
            == .hostname("127.0.0.1", port: PadServersTestConstants.deliveryPort))
    #expect(
        servers.makeTailnetDeliveryApplication().configuration.address
            == .hostname(PadServersTestConstants.tailnetAddress, port: PadServersTestConstants.deliveryPort))
}
