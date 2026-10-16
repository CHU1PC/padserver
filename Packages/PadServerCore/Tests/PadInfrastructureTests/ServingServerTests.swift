import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
@testable import PadInfrastructure
import PadTestSupport
import Testing

private enum ServingServerTestConstants {
    static let port = 8080
}

@Test func servingServerBindsOnlyToLoopback() {
    let application = ServingServer.makeApplication(
        port: ServingServerTestConstants.port, resolveRoute: ResolveRoute(storage: InMemoryProjectStorage())
    ) { _, _, _ in Response(status: .ok) }

    #expect(application.configuration.address == .hostname("127.0.0.1", port: ServingServerTestConstants.port))
}

@Test func servingServerReturnsNotFoundForUnmatchedHostAndPath() async throws {
    let application = ServingServer.makeApplication(
        port: ServingServerTestConstants.port, resolveRoute: ResolveRoute(storage: InMemoryProjectStorage())
    ) { _, _, _ in
        Issue.record("Unmatched requests must not be dispatched")
        return Response(status: .ok)
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/missing", method: .get)
        #expect(response.status == .notFound)
    }
}

@Test func servingServerDispatchesLongestRouteWithOriginalRequest() async throws {
    let storage = InMemoryProjectStorage()
    let root = try servingRoute(project: "root", prefix: "/")
    let docs = try servingRoute(project: "docs", prefix: "/docs")
    try await storage.saveProject(Project(name: root.project, kind: .staticSite), routes: [root])
    try await storage.saveProject(Project(name: docs.project, kind: .staticSite), routes: [docs])
    let application = servingTestApplication(storage: storage, authority: "EXAMPLE.COM.:8080") { route, request, _ in
        #expect(route == docs)
        #expect(request.method == .post)
        #expect(request.uri.path == "/docs/page")
        #expect(request.head.path == "/docs/page?view=raw")
        #expect(request.headers[.contentType] == "text/plain")
        let body = try await request.body.collect(upTo: 16)
        #expect(String(buffer: body) == "payload")
        return Response(status: .accepted, body: .init(byteBuffer: body))
    }
    try await application.test(.router) { client in
        let response = try await client.execute(
            uri: "/docs/page?view=raw", method: .post,
            headers: [.contentType: "text/plain"], body: .init(string: "payload")
        )
        #expect(response.status == .accepted)
        #expect(String(buffer: response.body) == "payload")
    }
}

@Test func servingServerReturnsUnavailableForStoppedLongestRoute() async throws {
    let storage = InMemoryProjectStorage()
    let root = try servingRoute(project: "root", prefix: "/")
    let docs = try servingRoute(project: "docs", prefix: "/docs")
    try await storage.saveProject(Project(name: root.project, kind: .staticSite), routes: [root])
    try await storage.saveProject(Project(name: docs.project, kind: .staticSite), routes: [docs])
    try await storage.saveProjectRunState(.stopped, for: docs.project)
    let application = servingTestApplication(storage: storage, authority: "example.com") { _, _, _ in
        Issue.record("Stopped routes must not dispatch or fall back to a shorter route")
        return Response(status: .ok)
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/docs/page", method: .get)
        #expect(response.status == .serviceUnavailable)
    }
}

@Test func servingServerRejectsAmbiguousRoutes() async throws {
    let storage = InMemoryProjectStorage()
    let first = try servingRoute(project: "first", prefix: "/docs")
    let second = try servingRoute(project: "second", prefix: "/docs")
    try await storage.saveProject(Project(name: first.project, kind: .staticSite), routes: [first])
    try await storage.saveProject(Project(name: second.project, kind: .staticSite), routes: [second])
    let application = servingTestApplication(storage: storage, authority: "example.com") { _, _, _ in
        Issue.record("Ambiguous routes must not be dispatched")
        return Response(status: .ok)
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/docs/page", method: .get)
        #expect(response.status == .notFound)
    }
}

@Test(
    arguments: [
        nil, "", "invalid host", "other.example.com", "example.com:garbage", "example.com:", "example.com:80:90",
    ] as [String?])
func servingServerRejectsMissingInvalidAndUnmatchedAuthority(authority: String?) async throws {
    let storage = InMemoryProjectStorage()
    let route = try servingRoute(project: "site", prefix: "/")
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let application = servingTestApplication(storage: storage, authority: authority) { _, _, _ in
        Issue.record("Invalid or unmatched authority must not be dispatched")
        return Response(status: .ok)
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get)
        #expect(response.status == .notFound)
    }
}

@Test func servingServerHonorsPrefixBoundaries() async throws {
    let storage = InMemoryProjectStorage()
    let route = try servingRoute(project: "site", prefix: "/docs")
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let application = servingTestApplication(storage: storage, authority: "example.com") { _, _, _ in
        Response(status: .ok)
    }
    try await application.test(.router) { client in
        let exact = try await client.execute(uri: "/docs", method: .get)
        let child = try await client.execute(uri: "/docs/page", method: .get)
        let outside = try await client.execute(uri: "/docsmith", method: .get)
        #expect(exact.status == .ok)
        #expect(child.status == .ok)
        #expect(outside.status == .notFound)
    }
}

private func servingRoute(project: String, prefix: String) throws -> Route {
    Route(
        project: try ProjectName(project), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix(prefix), target: .staticSite)
}

private func servingTestApplication(
    storage: InMemoryProjectStorage,
    authority: String?,
    handleRoute: @escaping @Sendable (Route, Request, BasicRequestContext) async throws -> Response
) -> Application<CallbackResponder<BasicRequestContext>> {
    let application = ServingServer.makeApplication(
        port: ServingServerTestConstants.port, resolveRoute: ResolveRoute(storage: storage), handleRoute: handleRoute
    )
    // Hummingbird の router 試験は authority を localhost に固定するため、ここで指定し直します。
    return Application(
        responder: CallbackResponder<BasicRequestContext> { request, context in
            var head = request.head
            head.authority = authority
            return try await application.responder.respond(
                to: Request(head: head, body: request.body), context: context)
        })
}
