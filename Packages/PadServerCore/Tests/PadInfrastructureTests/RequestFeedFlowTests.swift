import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
@testable import PadInfrastructure
import PadInterface
import PadTestSupport
import Testing

@Test func servedRequestAppearsInRequestFeedWithinOneSecond() async throws {
    let storage = InMemoryProjectStorage()
    let bus = PadInfrastructure.InMemoryLogBus()
    let route = Route(
        project: try ProjectName("site"), host: try RouteHost("example.com"),
        pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    try await storage.saveProject(Project(name: route.project, kind: .staticSite), routes: [route])
    let serving = ServingServer.makeApplication(
        port: 8080, resolveRoute: ResolveRoute(storage: storage), logBus: bus
    ) { _, _, _ in Response(status: .ok) }
    let application = Application(
        responder: CallbackResponder<BasicRequestContext> { request, context in
            var head = request.head
            head.authority = "example.com"
            return try await serving.responder.respond(to: Request(head: head, body: request.body), context: context)
        })

    let stream = await bus.subscribe()
    try await application.test(.router) { client in
        _ = try await client.execute(uri: "/hello", method: .get)
    }

    var presenter = RequestFeedPresenter()
    let clock = ContinuousClock()
    let started = clock.now
    var iterator = stream.makeAsyncIterator()
    let entry = try #require(await iterator.next())
    presenter.receive(entry)

    #expect(started.duration(to: clock.now) < .seconds(1))
    #expect(presenter.rows.map(\.path) == ["/hello"])
    #expect(presenter.rows.first?.status == 200)
}
