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
    static let blobHashText = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
    static let etag = "\"\(blobHashText)\""
}

private struct RangeExpectation {
    let range: String
    let body: String
    let contentRange: String
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
        #expect(response.headers[.eTag] == StaticTestConstants.etag)
        #expect(String(buffer: response.body) == "<h1>hello</h1>")

        let unchanged = try await client.execute(
            uri: "/", method: .get, headers: [.ifNoneMatch: StaticTestConstants.etag])
        #expect(unchanged.status == .notModified)
        #expect(unchanged.headers[.eTag] == StaticTestConstants.etag)
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

@Test func staticFileResponderServesSingleByteRanges() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await staticRelease(storage: storage, route: route, path: "index.html", content: "0123456789")
    let application = staticApplication(storage: storage, route: route)
    let cases = [
        RangeExpectation(range: "bytes=2-5", body: "2345", contentRange: "bytes 2-5/10"),
        RangeExpectation(range: "bytes=8-", body: "89", contentRange: "bytes 8-9/10"),
        RangeExpectation(range: "bytes=-3", body: "789", contentRange: "bytes 7-9/10"),
        RangeExpectation(range: "bytes=8-20", body: "89", contentRange: "bytes 8-9/10"),
    ]
    try await application.test(.router) { client in
        for testCase in cases {
            let response = try await client.execute(uri: "/", method: .get, headers: [.range: testCase.range])
            #expect(response.status == .partialContent)
            #expect(response.headers[.contentRange] == testCase.contentRange)
            #expect(response.headers[.contentLength] == String(testCase.body.utf8.count))
            #expect(response.headers[.acceptRanges] == "bytes")
            #expect(String(buffer: response.body) == testCase.body)
        }
    }
}

@Test func staticFileResponderRejectsUnsatisfiableRange() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await staticRelease(storage: storage, route: route, path: "index.html", content: "0123456789")
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get, headers: [.range: "bytes=10-"])
        #expect(response.status == .rangeNotSatisfiable)
        #expect(response.headers[.contentRange] == "bytes */10")
        #expect(response.body.readableBytes == 0)
    }
}

@Test func staticFileResponderIgnoresMultipleRanges() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await staticRelease(storage: storage, route: route, path: "index.html", content: "0123456789")
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get, headers: [.range: "bytes=0-1,3-4"])
        #expect(response.status == .ok)
        #expect(response.headers[.contentRange] == nil)
        #expect(String(buffer: response.body) == "0123456789")

        let invalid = try await client.execute(uri: "/", method: .get, headers: [.range: "bytes=8-7"])
        #expect(invalid.status == .ok)
        #expect(String(buffer: invalid.body) == "0123456789")
    }
}

@Test func staticFileResponderRejectsRangeForEmptyBlob() async throws {
    let storage = InMemoryProjectStorage()
    let route = try staticRoute(prefix: "/")
    try await staticRelease(storage: storage, route: route, path: "index.html", content: "")
    let application = staticApplication(storage: storage, route: route)
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/", method: .get, headers: [.range: "bytes=0-0"])
        #expect(response.status == .rangeNotSatisfiable)
        #expect(response.headers[.contentRange] == "bytes */0")

        let suffix = try await client.execute(uri: "/", method: .get, headers: [.range: "bytes=-1"])
        #expect(suffix.status == .ok)
        #expect(suffix.body.readableBytes == 0)
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
    let hash = try BlobHash(StaticTestConstants.blobHashText)
    let body = BlobBodyStream {
        let cursor = StaticTestBodyCursor(Data(content.utf8))
        return { await cursor.next() }
    }
    try await storage.saveBlob(hash, from: body)
    let release = Release(id: ReleaseID(UUID()), project: route.project, state: .preparing)
    try await storage.saveRelease(release, manifest: ReleaseManifest(files: [try .init(path: path, blob: hash)]))
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
