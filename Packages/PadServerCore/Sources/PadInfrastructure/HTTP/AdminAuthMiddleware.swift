import Hummingbird
import PadApplication
import PadDomain

public struct AdminAuthMiddleware: RouterMiddleware {
    private let authorizeAdmin: AuthorizeAdmin

    public init(authorizeAdmin: AuthorizeAdmin) {
        self.authorizeAdmin = authorizeAdmin
    }

    public func handle(
        _ request: Request, context: AdminRequestContext,
        next: (Request, AdminRequestContext) async throws -> Response
    ) async throws -> Response {
        guard let authorization = request.headers[.authorization],
            authorization.prefix("Bearer ".count).lowercased() == "bearer "
        else {
            return Response(status: .unauthorized)
        }
        let token = String(authorization.dropFirst("Bearer ".count))
        guard !token.isEmpty else {
            return Response(status: .unauthorized)
        }

        let address = context.clientAddress ?? ClientAddress("")
        switch try await authorizeAdmin(token: AdminToken(token), address: address) {
        case .authorized:
            return try await next(request, context)

        case .unauthorized:
            return Response(status: .unauthorized)

        case .forbidden:
            return Response(status: .forbidden)
        }
    }
}
