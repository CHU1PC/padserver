import Foundation
import Hummingbird
import HummingbirdTesting
import HTTPTypes
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import PadTestSupport
import Testing

private let releaseUUID = UUID(uuidString: "00000000-0000-4000-8000-000000000001")

private actor StubGuestController: GuestController {
    private var current: GuestState

    init(current: GuestState) {
        self.current = current
    }

    func state() -> GuestState { current }
    func start() { current = .starting }
    func stop() { current = .stopped }
}

private func makeApplication(
    storage: InMemoryProjectStorage, guest: (any GuestController)? = nil
) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router(context: BasicRequestContext.self)
    ProjectController(
        listProjects: ListProjects(storage: storage), setProjectState: SetProjectState(storage: storage),
        guestController: guest
    ).addRoutes(to: router)
    return Application(responder: router.buildResponder())
}

private func seed(_ storage: InMemoryProjectStorage, name: String) async throws -> Project {
    let project = Project(name: try ProjectName(name), kind: .staticSite)
    try await storage.saveProject(project, routes: [])
    return project
}

private func activate(_ storage: InMemoryProjectStorage, project: Project) async throws -> Release {
    let id = ReleaseID(try #require(releaseUUID))
    try await storage.saveRelease(Release(id: id, project: project.name, state: .preparing), manifest: .init(files: []))
    try await storage.activateRelease(id, for: project.name)
    return Release(id: id, project: project.name, state: .active)
}

private func decodeError(_ body: ByteBuffer) throws -> AdminErrorResponse {
    try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: Data(buffer: body))
}

@Test func projectControllerListsProjectsWithActiveReleaseAndRunState() async throws {
    let storage = InMemoryProjectStorage()
    let site = try await seed(storage, name: "site")
    let release = try await activate(storage, project: site)
    let other = try await seed(storage, name: "other")
    try await storage.saveProjectRunState(.stopped, for: other.name)

    try await makeApplication(storage: storage).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects", method: .get)

        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        let body = try AdminAPIJSON.makeDecoder().decode(AdminProjectsResponse.self, from: Data(buffer: response.body))
        #expect(
            body.projects == [
                AdminProjectStatus(project: site, activeRelease: release, running: true),
                AdminProjectStatus(project: other, activeRelease: nil, running: false),
            ])
    }
}

@Test func projectControllerEncodesMissingActiveReleaseAsNull() async throws {
    let storage = InMemoryProjectStorage()
    _ = try await seed(storage, name: "site")

    try await makeApplication(storage: storage).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects", method: .get)

        let text = String(buffer: response.body)
        #expect(text.contains("\"activeRelease\":null"))
    }
}

@Test func projectControllerReturnsEmptyListWithoutProjects() async throws {
    try await makeApplication(storage: InMemoryProjectStorage()).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects", method: .get)

        #expect(response.status == .ok)
        let body = try AdminAPIJSON.makeDecoder().decode(AdminProjectsResponse.self, from: Data(buffer: response.body))
        #expect(body.projects.isEmpty)
    }
}

@Test func projectControllerStopsAndStartsProjectAndReturnsUpdatedStatus() async throws {
    let storage = InMemoryProjectStorage()
    let site = try await seed(storage, name: "site")
    let release = try await activate(storage, project: site)

    try await makeApplication(storage: storage).test(.router) { client in
        let stopped = try await client.execute(uri: "/v1/projects/site/stop", method: .post)

        #expect(stopped.status == .ok)
        let stoppedBody = try AdminAPIJSON.makeDecoder().decode(
            AdminProjectStatus.self, from: Data(buffer: stopped.body))
        #expect(stoppedBody == AdminProjectStatus(project: site, activeRelease: release, running: false))
        #expect(try await storage.projectRunState(for: site.name) == .stopped)

        let started = try await client.execute(uri: "/v1/projects/site/start", method: .post)

        #expect(started.status == .ok)
        let startedBody = try AdminAPIJSON.makeDecoder().decode(
            AdminProjectStatus.self, from: Data(buffer: started.body))
        #expect(startedBody == AdminProjectStatus(project: site, activeRelease: release, running: true))
        #expect(try await storage.projectRunState(for: site.name) == .running)
    }
}

@Test(arguments: ["start", "stop"])
func projectControllerReturnsNotFoundForUnknownProject(action: String) async throws {
    let storage = InMemoryProjectStorage()
    let site = try await seed(storage, name: "site")

    try await makeApplication(storage: storage).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/unknown/\(action)", method: .post)

        #expect(response.status == .notFound)
        #expect(try decodeError(response.body).error.code == .projectNotFound)
        #expect(try await storage.projectRunState(for: site.name) == .running)
    }
}

@Test(arguments: ["start", "stop"])
func projectControllerRejectsInvalidProjectName(action: String) async throws {
    try await makeApplication(storage: InMemoryProjectStorage()).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/Bad_Name/\(action)", method: .post)

        #expect(response.status == .badRequest)
        #expect(try decodeError(response.body).error.code == .invalidRequest)
    }
}

@Test func projectControllerRoutesRequireAdminAuthentication() async throws {
    let storage = InMemoryProjectStorage()
    _ = try await seed(storage, name: "site")
    let application = try AdminServer.makeApplication(
        adminPort: 8081,
        deliveryPort: 8080,
        tailnetAddress: "100.64.0.1",
        authorizeAdmin: AuthorizeAdmin(secretStore: InMemorySecretStore())
    ) { router in
        ProjectController(
            listProjects: ListProjects(storage: storage), setProjectState: SetProjectState(storage: storage)
        ).addRoutes(to: router)
    }

    try await application.test(.router) { client in
        let list = try await client.execute(uri: "/v1/projects", method: .get)
        let stop = try await client.execute(uri: "/v1/projects/site/stop", method: .post)

        #expect(list.status == .unauthorized)
        #expect(stop.status == .unauthorized)
        #expect(try await storage.projectRunState(for: ProjectName("site")) == .running)
    }
}

@Test(arguments: [
    (GuestState.stopped, "stopped"), (GuestState.starting, "starting"),
    (GuestState.ready, "ready"), (GuestState.failed, "failed"),
])
func projectControllerReportsGuestState(state: GuestState, wireValue: String) async throws {
    let app = makeApplication(storage: InMemoryProjectStorage(), guest: StubGuestController(current: state))

    try await app.test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects", method: .get)

        #expect(response.status == .ok)
        #expect(String(buffer: response.body).contains("\"guest\":{\"state\":\"\(wireValue)\"}"))
        let body = try AdminAPIJSON.makeDecoder().decode(AdminProjectsResponse.self, from: Data(buffer: response.body))
        #expect(body.guest == AdminGuestStatus(state: state))
    }
}

@Test func projectControllerOmitsGuestWithoutGuestController() async throws {
    try await makeApplication(storage: InMemoryProjectStorage()).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects", method: .get)

        #expect(!String(buffer: response.body).contains("guest"))
    }
}
