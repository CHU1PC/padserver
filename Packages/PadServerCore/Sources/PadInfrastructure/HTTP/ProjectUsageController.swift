import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct ProjectUsageController: Sendable {
    private let getProjectUsage: GetProjectUsage

    public init(getProjectUsage: GetProjectUsage) {
        self.getProjectUsage = getProjectUsage
    }

    public func addRoutes<Context: RequestContext>(to router: Router<Context>) {
        router.get("/v1/projects/{name}/usage") { _, context in
            let name: ProjectName
            do {
                name = try ProjectName(context.parameters.get("name") ?? "")
            } catch {
                return try Self.errorResponse(.badRequest, .invalidRequest, "Project name is invalid.")
            }
            do {
                let usage = try await getProjectUsage(of: name)
                return try Self.jsonResponse(AdminProjectUsageResponse(usage: usage.map(AdminProjectUsage.init)))
            } catch GetProjectUsage.Failure.projectNotFound {
                return try Self.errorResponse(.notFound, .projectNotFound, "Project was not found.")
            }
        }
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
