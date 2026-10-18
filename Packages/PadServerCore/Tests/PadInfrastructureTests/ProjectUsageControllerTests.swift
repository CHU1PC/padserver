import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import PadTestSupport
import Testing

private let measuredAt = Date(timeIntervalSince1970: 0)

private func makeController(
    storage: InMemoryProjectStorage, usages: [ProjectName: ProjectUsage]
) -> ProjectUsageController {
    ProjectUsageController(
        getProjectUsage: GetProjectUsage(storage: storage, usageSource: FixedUsageSource(usages: usages)))
}

private func makeApplication(
    storage: InMemoryProjectStorage, usages: [ProjectName: ProjectUsage] = [:]
) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router(context: BasicRequestContext.self)
    makeController(storage: storage, usages: usages).addRoutes(to: router)
    return Application(responder: router.buildResponder())
}

private func seed(_ storage: InMemoryProjectStorage, name: String) async throws -> ProjectName {
    let project = Project(name: try ProjectName(name), kind: .compose)
    try await storage.saveProject(project, routes: [])
    return project.name
}

private func decodeError(_ body: ByteBuffer) throws -> AdminErrorResponse {
    try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: Data(buffer: body))
}

@Test func projectUsageControllerReturnsUsageOfMeasuredProject() async throws {
    let storage = InMemoryProjectStorage()
    let name = try await seed(storage, name: "app")
    let usage = try ProjectUsage(cpuUsage: 1.5, memoryBytes: 2_048, measuredAt: measuredAt)

    try await makeApplication(storage: storage, usages: [name: usage]).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/app/usage", method: .get)

        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/json")
        let body = try AdminAPIJSON.makeDecoder().decode(
            AdminProjectUsageResponse.self, from: Data(buffer: response.body))
        #expect(body.usage == AdminProjectUsage(cpuUsage: 1.5, memoryBytes: 2_048, measuredAt: measuredAt))
        #expect(String(buffer: response.body).contains("\"measuredAt\":\"1970-01-01T00:00:00Z\""))
    }
}

@Test func projectUsageControllerEncodesUnmeasuredProjectAsNull() async throws {
    let storage = InMemoryProjectStorage()
    _ = try await seed(storage, name: "blog")

    try await makeApplication(storage: storage).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/blog/usage", method: .get)

        #expect(response.status == .ok)
        #expect(String(buffer: response.body) == "{\"usage\":null}")
    }
}

@Test func projectUsageControllerReturnsNotFoundForUnknownProject() async throws {
    let storage = InMemoryProjectStorage()
    _ = try await seed(storage, name: "app")

    try await makeApplication(storage: storage).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/unknown/usage", method: .get)

        #expect(response.status == .notFound)
        #expect(try decodeError(response.body).error.code == .projectNotFound)
    }
}

@Test func projectUsageControllerRejectsInvalidProjectName() async throws {
    try await makeApplication(storage: InMemoryProjectStorage()).test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/Bad_Name/usage", method: .get)

        #expect(response.status == .badRequest)
        #expect(try decodeError(response.body).error.code == .invalidRequest)
    }
}

@Test func projectUsageControllerRouteRequiresAdminAuthentication() async throws {
    let storage = InMemoryProjectStorage()
    let name = try await seed(storage, name: "app")
    let usage = try ProjectUsage(cpuUsage: 0.5, memoryBytes: 1, measuredAt: measuredAt)
    let controller = makeController(storage: storage, usages: [name: usage])
    let application = try AdminServer.makeApplication(
        adminPort: 8081,
        deliveryPort: 8080,
        tailnetAddress: "100.64.0.1",
        authorizeAdmin: AuthorizeAdmin(secretStore: InMemorySecretStore())
    ) { router in
        controller.addRoutes(to: router)
    }

    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/v1/projects/app/usage", method: .get)

        #expect(response.status == .unauthorized)
    }
}
