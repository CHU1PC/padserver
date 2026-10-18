import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct ProjectController: Sendable {
    private let listProjects: ListProjects
    private let setProjectState: SetProjectState
    private let guestController: (any GuestController)?

    public init(
        listProjects: ListProjects, setProjectState: SetProjectState, guestController: (any GuestController)? = nil
    ) {
        self.listProjects = listProjects
        self.setProjectState = setProjectState
        self.guestController = guestController
    }

    public func addRoutes<Context: RequestContext>(to router: Router<Context>) {
        router.get("/v1/projects") { _, _ in
            let statuses = try await listProjects()
            let guest = await guestController?.state()
            return try Self.jsonResponse(
                AdminProjectsResponse(
                    projects: statuses.map(Self.adminStatus), guest: guest.map { AdminGuestStatus(state: $0) }))
        }
        router.post("/v1/projects/{name}/start") { _, context in
            try await changeState(.running, parameters: context.parameters)
        }
        router.post("/v1/projects/{name}/stop") { _, context in
            try await changeState(.stopped, parameters: context.parameters)
        }
    }

    private func changeState(_ state: ProjectRunState, parameters: Parameters) async throws -> Response {
        let name: ProjectName
        do {
            name = try ProjectName(parameters.get("name") ?? "")
        } catch {
            return try Self.errorResponse(.badRequest, .invalidRequest, "Project name is invalid.")
        }
        guard try await listProjects().contains(where: { $0.project.name == name }) else {
            return try Self.errorResponse(.notFound, .projectNotFound, "Project was not found.")
        }
        try await setProjectState(state, for: name)
        guard let updated = try await listProjects().first(where: { $0.project.name == name }) else {
            return try Self.errorResponse(.notFound, .projectNotFound, "Project was not found.")
        }
        return try Self.jsonResponse(Self.adminStatus(updated))
    }

    private static func adminStatus(_ status: ListProjects.Status) -> AdminProjectStatus {
        AdminProjectStatus(project: status.project, activeRelease: status.activeRelease, running: status.running)
    }

    private static func errorResponse(
        _ status: HTTPResponse.Status, _ code: AdminErrorCode, _ message: String
    ) throws -> Response {
        try jsonResponse(AdminErrorResponse(error: AdminError(code: code, message: message)), status: status)
    }

    private static func jsonResponse<Body: Encodable>(
        _ body: Body, status: HTTPResponse.Status = .ok
    ) throws -> Response {
        let data = try AdminAPIJSON.makeEncoder().encode(body)
        return Response(
            status: status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(bytes: data))
        )
    }
}
