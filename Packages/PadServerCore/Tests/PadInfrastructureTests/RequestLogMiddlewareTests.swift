import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
@testable import PadInfrastructure
import PadTestSupport
import Testing

private enum RequestLogTestConstants {
    static let port = 8080
}

@Test func requestLogMiddlewarePublishesResponseAndMissingRoute() async throws {
    let storage = InMemoryProjectStorage()
    let bus = PadInfrastructure.InMemoryLogBus()
    let route = Route(
        project: try ProjectName("site"), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/docs"), target: .staticSite)
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let application = loggedApplication(storage: storage, bus: bus) { _, _, _ in Response(status: .accepted) }

    let before = Date()
    try await application.test(.router) { client in
        let found = try await client.execute(uri: "/docs/page", method: .get)
        let missing = try await client.execute(uri: "/missing", method: .get)
        #expect(found.status == .accepted)
        #expect(missing.status == .notFound)
    }
    let after = Date()

    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()
    let foundEntry = await iterator.next()
    let missingEntry = await iterator.next()
    expectLogEntries(foundEntry: foundEntry, missingEntry: missingEntry, before: before, after: after)
}

private func expectLogEntries(foundEntry: LogEntry?, missingEntry: LogEntry?, before: Date, after: Date) {
    if let foundEntry, let missingEntry {
        #expect(foundEntry.timestamp >= before)
        #expect(foundEntry.timestamp <= after)
        #expect(foundEntry.source == "serving")
        #expect(foundEntry.level == .info)
        #expect(foundEntry.message.contains("host=example.com path=/docs/page status=202 duration_ms="))
        #expect(missingEntry.message.contains("host=example.com path=/missing status=404 duration_ms="))
        #expect(Double(foundEntry.message.components(separatedBy: "duration_ms=").last ?? "").map { $0 >= 0 } == true)
    } else {
        Issue.record("Every serving request must produce a log entry")
    }
}

@Test func requestLogMiddlewarePublishesFailedRequestStatus() async throws {
    let storage = InMemoryProjectStorage()
    let bus = PadInfrastructure.InMemoryLogBus()
    let route = Route(
        project: try ProjectName("site"), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let application = loggedApplication(storage: storage, bus: bus) { _, _, _ in throw HTTPError(.forbidden) }

    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/private", method: .get)
        #expect(response.status == .internalServerError)
    }
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()
    let entry = await iterator.next()
    #expect(entry?.message.contains("host=example.com path=/private status=500 duration_ms=") == true)
}

@Test func requestLogMiddlewareAttachesProjectNameForMatchedRoute() async throws {
    let storage = InMemoryProjectStorage()
    let bus = PadInfrastructure.InMemoryLogBus()
    let route = Route(
        project: try ProjectName("site"), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/docs"), target: .staticSite)
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let application = loggedApplication(storage: storage, bus: bus) { _, _, _ in Response(status: .ok) }

    try await application.test(.router) { client in
        _ = try await client.execute(uri: "/docs/page", method: .get)
    }
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()
    let entry = await iterator.next()
    #expect(entry?.project == "site")
}

@Test func requestLogMiddlewareLeavesProjectNameEmptyForMissingRoute() async throws {
    let storage = InMemoryProjectStorage()
    let bus = PadInfrastructure.InMemoryLogBus()
    let application = loggedApplication(storage: storage, bus: bus) { _, _, _ in Response(status: .ok) }

    try await application.test(.router) { client in
        _ = try await client.execute(uri: "/missing", method: .get)
    }
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()
    let entry = await iterator.next()
    #expect(entry?.message.contains("status=404") == true)
    #expect(entry?.project == nil)
}

@Test func requestLogMiddlewareAttachesProjectNameForStoppedProject() async throws {
    let storage = InMemoryProjectStorage()
    let bus = PadInfrastructure.InMemoryLogBus()
    let route = Route(
        project: try ProjectName("site"), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    try await storage.saveProjectRunState(.stopped, for: route.project)
    let application = loggedApplication(storage: storage, bus: bus) { _, _, _ in Response(status: .ok) }

    try await application.test(.router) { client in
        _ = try await client.execute(uri: "/", method: .get)
    }
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()
    let entry = await iterator.next()
    #expect(entry?.message.contains("status=503") == true)
    #expect(entry?.project == "site")
}

private func loggedApplication(
    storage: InMemoryProjectStorage, bus: PadInfrastructure.InMemoryLogBus,
    handleRoute: @escaping @Sendable (Route, Request, BasicRequestContext) async throws -> Response
) -> Application<CallbackResponder<BasicRequestContext>> {
    let serving = ServingServer.makeApplication(
        port: RequestLogTestConstants.port, resolveRoute: ResolveRoute(storage: storage), logBus: bus,
        handleRoute: handleRoute)
    return Application(
        responder: CallbackResponder<BasicRequestContext> { request, context in
            var head = request.head
            head.authority = "example.com"
            return try await serving.responder.respond(to: Request(head: head, body: request.body), context: context)
        })
}
