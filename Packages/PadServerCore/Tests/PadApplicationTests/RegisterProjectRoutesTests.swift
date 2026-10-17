import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func registerProjectRoutesRejectsDuplicateAcrossProjectsWithoutChangingExistingRoutes() async throws {
    let host = try RouteHost("site.example.com")
    let prefix = try RoutePathPrefix("/api")
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    let original = Route(project: first, host: host, pathPrefix: prefix, target: .staticSite)
    let duplicate = Route(project: second, host: host, pathPrefix: prefix, target: .staticSite)
    let storage = InMemoryProjectStorage()
    let register = RegisterProjectRoutes(storage: storage)
    try await register(Project(name: first, kind: .staticSite), routes: [original])

    await #expect(throws: RegisterProjectRoutes.Error.duplicateRoute) {
        try await register(Project(name: second, kind: .staticSite), routes: [duplicate])
    }
    #expect(try await storage.listRoutes() == [original])
    #expect(try await storage.listProjects().map(\.name) == [first])
}

@Test func registerProjectRoutesAcceptsDistinctHostOrPrefix() async throws {
    let host = try RouteHost("site.example.com")
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    let base = Route(project: first, host: host, pathPrefix: try RoutePathPrefix("/api"), target: .staticSite)
    let otherHost = Route(
        project: second, host: try RouteHost("other.example.com"),
        pathPrefix: base.pathPrefix, target: .staticSite)
    let otherPrefix = Route(project: second, host: host, pathPrefix: try RoutePathPrefix("/web"), target: .staticSite)
    let storage = InMemoryProjectStorage()
    let register = RegisterProjectRoutes(storage: storage)
    try await register(Project(name: first, kind: .staticSite), routes: [base])
    try await register(Project(name: second, kind: .staticSite), routes: [otherHost, otherPrefix])

    #expect(try await storage.listRoutes() == [base, otherHost, otherPrefix])
}

@Test func registerProjectRoutesRejectsDuplicatesWithinOneRegistration() async throws {
    let project = try ProjectName("site")
    let route = Route(
        project: project, host: try RouteHost("site.example.com"),
        pathPrefix: try RoutePathPrefix("/"), target: .staticSite)
    let storage = InMemoryProjectStorage()

    await #expect(throws: RegisterProjectRoutes.Error.duplicateRoute) {
        try await RegisterProjectRoutes(storage: storage)(
            Project(name: project, kind: .staticSite), routes: [route, route])
    }
    #expect(try await storage.listRoutes().isEmpty)
}

@Test func registerProjectRoutesRejectsOneOfTwoConcurrentDuplicates() async throws {
    let host = try RouteHost("site.example.com")
    let prefix = try RoutePathPrefix("/api")
    let first = try ProjectName("first")
    let second = try ProjectName("second")
    let storage = InMemoryProjectStorage()
    let register = RegisterProjectRoutes(storage: storage)
    let firstRoute = Route(project: first, host: host, pathPrefix: prefix, target: .staticSite)
    let secondRoute = Route(project: second, host: host, pathPrefix: prefix, target: .staticSite)
    let attempts = [
        Task { await attemptRegistration(register, project: first, route: firstRoute) },
        Task { await attemptRegistration(register, project: second, route: secondRoute) },
    ]
    let results = [await attempts[0].value, await attempts[1].value]

    #expect(results.filter { $0 }.count == 1)
    #expect(results.filter { !$0 }.count == 1)
    #expect(try await storage.listRoutes().count == 1)
}

private func attemptRegistration(_ register: RegisterProjectRoutes, project: ProjectName, route: Route) async -> Bool {
    do {
        try await register(Project(name: project, kind: .staticSite), routes: [route])
        return true
    } catch RegisterProjectRoutes.Error.duplicateRoute {
        return false
    } catch {
        Issue.record("Unexpected registration error: \(error)")
        return false
    }
}
