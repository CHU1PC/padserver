import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
@testable import PadInfrastructure
import PadTestSupport
import Testing

private enum StaticTestConstants {
    static let port = 8080
}

@Test func staticFileResponderServesActiveRootIndexAndConditionalResponse() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await staticRelease(storage: storage, route: route, path: "index.html", content: "<h1>hello</h1>")
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "text/html")
        #expect(response.headers[.eTag] == "\"test-blob\"")
        #expect(String(buffer: response.body) == "<h1>hello</h1>")

        let unchanged = try await client.execute(
            uri: "/", method: .get, headers: [.ifNoneMatch: "\"test-blob\""])
        #expect(unchanged.status == .notModified)
        #expect(unchanged.headers[.eTag] == "\"test-blob\"")
        #expect(unchanged.body.readableBytes == 0)

        let changed = try await client.execute(
            uri: "/", method: .get, headers: [.ifNoneMatch: "\"other-blob\""])
        #expect(changed.status == .ok)
        #expect(String(buffer: changed.body) == "<h1>hello</h1>")
    }
}

@Test func staticFileResponderUsesRoutePrefixAndManifestRelativePath() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/docs")
    try await staticRelease(storage: storage, route: route, path: "guide/page.txt", content: "guide")
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let found = try await client.execute(uri: "/docs/guide/page.txt", method: .get)
        #expect(found.status == .ok)
        #expect(found.headers[.contentType] == "text/plain")
        #expect(String(buffer: found.body) == "guide")
        let missing = try await client.execute(uri: "/docs/page.txt", method: .get)
        #expect(missing.status == .notFound)
    }
}

@Test(arguments: ["/../index.html", "/%2e%2e/index.html", "/docs/../index.html", "/docs/%2e%2e/index.html"])
func staticFileResponderRejectsParentSegments(path: String) async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await staticRelease(storage: storage, route: route, path: "index.html", content: "private")
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let response = try await client.execute(uri: path, method: .get)
        #expect(response.status == .notFound)
    }
}

@Test func staticFileResponderReturnsNotFoundWithoutActiveRelease() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get)
        #expect(response.status == .notFound)
    }
}

private func staticRoute(prefix: String) throws -> Route {
    Route(
        project: try ProjectName("site"), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix(prefix), target: .staticSite)
}

private func staticRelease(
    storage: InMemoryProjectStorage, route: Route, path: String, content: String
) async throws {
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let hash = BlobHash("test-blob")
    let body = BlobBodyStream {
        let cursor = StaticTestBodyCursor(Data(content.utf8))
        return { await cursor.next() }
    }
    try await storage.saveBlob(hash, from: body)
    let release = Release(id: ReleaseID(UUID()), project: route.project, state: .preparing)
    try await storage.saveRelease(release, manifest: ReleaseManifest(files: [.init(path: path, blob: hash)]))
    try await storage.activateRelease(release.id, for: route.project)
}

private func staticApplication(
    storage: InMemoryProjectStorage, route: Route
) -> Application<CallbackResponder<BasicRequestContext>> {
    let responder = StaticFileResponder(storage: storage)
    let application = ServingServer.makeApplication(
        port: StaticTestConstants.port, resolveRoute: ResolveRoute(storage: storage)
    ) { route, request, context in
        try await responder.respond(to: request, route: route, context: context)
    }
    return Application(
        responder: CallbackResponder<BasicRequestContext> { request, context in
            var head = request.head
            head.authority = route.host.value
            return try await application.responder.respond(
                to: Request(head: head, body: request.body), context: context)
        })
}

private actor StaticTestBodyCursor {
    private var data: Data?

    init(_ data: Data) { self.data = data }

    func next() -> Data? {
        defer { data = nil }
        return data
    }
}
