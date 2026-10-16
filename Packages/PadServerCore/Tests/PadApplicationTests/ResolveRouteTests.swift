import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func resolveRouteMatchesSubdomainAndPreservesTarget() async throws {
    let project = try ProjectName("site")
    let host = try RouteHost("site.example.com")
    let route = Route(project: project, host: host, pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [route])

    let result = try await ResolveRoute(storage: storage)(host: host, path: "/index.html")

    #expect(result == .matched(route))
}

@Test func resolveRouteChoosesLongestPathPrefix() async throws {
    let host = try RouteHost("example.com")
    let site = try ProjectName("site")
    let api = try ProjectName("api")
    let root = Route(project: site, host: host, pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    let prefix = Route(
        project: api, host: host, pathPrefix: try RoutePathPrefix("/api"),
        target: .container(try ContainerRouteTarget(service: "web", port: 8080)))
    let longest = Route(
        project: api, host: host, pathPrefix: try RoutePathPrefix("/api/v1"),
        target: .container(try ContainerRouteTarget(service: "api", port: 9000)))
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: site, kind: .staticSite), routes: [root])
    try await storage.saveProject(Project(name: api, kind: .compose), routes: [prefix, longest])
    let resolve = ResolveRoute(storage: storage)

    #expect(try await resolve(host: host, path: "/api/v1/users") == .matched(longest))
    #expect(try await resolve(host: host, path: "/api") == .matched(prefix))
    #expect(try await resolve(host: host, path: "/api/users") == .matched(prefix))
    #expect(try await resolve(host: host, path: "/apiary") == .matched(root))
}

@Test func resolveRouteDistinguishesStoppedProjectFromUnmatchedRoute() async throws {
    let host = try RouteHost("example.com")
    let rootProject = try ProjectName("site")
    let stoppedProject = try ProjectName("api")
    let root = Route(project: rootProject, host: host, pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    let stopped = Route(
        project: stoppedProject, host: host, pathPrefix: try RoutePathPrefix("/api"), target: .staticSite)
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: rootProject, kind: .staticSite), routes: [root])
    try await storage.saveProject(Project(name: stoppedProject, kind: .staticSite), routes: [stopped])
    try await storage.saveProjectRunState(.stopped, for: stoppedProject)
    let resolve = ResolveRoute(storage: storage)

    #expect(try await resolve(host: host, path: "/api/users") == .stopped(stoppedProject))
    #expect(try await resolve(host: try RouteHost("unknown.example.com"), path: "/api") == .notFound)
    #expect(try await resolve(host: host, path: "/") == .matched(root))
}

@Test func resolveRouteReturnsNotFoundForUnmatchedPathAndEmptyRoutes() async throws {
    let host = try RouteHost("example.com")
    let project = try ProjectName("api")
    let storage = InMemoryProjectStorage()
    let resolve = ResolveRoute(storage: storage)
    #expect(try await resolve(host: host, path: "/api") == .notFound)

    let route = Route(project: project, host: host, pathPrefix: try RoutePathPrefix("/api"), target: .staticSite)
    try await storage.saveProject(Project(name: project, kind: .staticSite), routes: [route])

    #expect(try await resolve(host: host, path: "/other") == .notFound)
    #expect(try await resolve(host: host, path: "/apiary") == .notFound)
}

@Test func resolveRouteRejectsAmbiguousLongestPrefixWithoutBlockingMoreSpecificRoute() async throws {
    let host = try RouteHost("example.com")
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    let root = Route(project: first, host: host, pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    let duplicate = Route(project: first, host: host, pathPrefix: try RoutePathPrefix("/api"), target: .staticSite)
    let other = Route(project: second, host: host, pathPrefix: try RoutePathPrefix("/api"), target: .staticSite)
    let specific = Route(project: first, host: host, pathPrefix: try RoutePathPrefix("/api/v2"), target: .staticSite)
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: first, kind: .staticSite), routes: [root, duplicate, specific])
    try await storage.saveProject(Project(name: second, kind: .staticSite), routes: [other])
    let resolve = ResolveRoute(storage: storage)

    #expect(try await resolve(host: host, path: "/api/users") == .ambiguous)
    #expect(try await resolve(host: host, path: "/api/v2/users") == .matched(specific))
    try await storage.saveProjectRunState(.stopped, for: second)
    #expect(try await resolve(host: host, path: "/api/users") == .ambiguous)
}
