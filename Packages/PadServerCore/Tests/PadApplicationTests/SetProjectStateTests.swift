import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func setProjectStateStopsRouteResolutionAndRestoresItOnStart() async throws {
    let project = try ProjectName("site")
    let host = try RouteHost("site.example.com")
    let route = Route(project: project, host: host, pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [route])
    let resolve = ResolveRoute(storage: storage)
    let setState = SetProjectState(storage: storage)
    #expect(try await resolve(host: host, path: "/index.html") == .matched(route))

    try await setState(.stopped, for: project)

    #expect(try await resolve(host: host, path: "/index.html") == .stopped(project))
    #expect(try await storage.listRoutes() == [route])

    try await setState(.running, for: project)

    #expect(try await resolve(host: host, path: "/index.html") == .matched(route))
}

@Test func setProjectStatePropagatesUnknownProjectFailureWithoutChangingOtherProjects() async throws {
    let project = try ProjectName("site")
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [])
    let setState = SetProjectState(storage: storage)

    await #expect(throws: (any Error).self) {
        try await setState(.stopped, for: ProjectName("unknown"))
    }

    #expect(try await storage.projectRunState(for: project) == .running)
}
