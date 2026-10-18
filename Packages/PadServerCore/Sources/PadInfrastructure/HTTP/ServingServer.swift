import Hummingbird
import PadApplication
import PadDomain

public enum ServingServer {
    // DNS の authority は host と任意の port の2要素だけを許可します。
    private static let maximumAuthorityParts = 2

    public static func makeApplication(
        address: String = "127.0.0.1",
        port: Int,
        resolveRoute: ResolveRoute,
        logBus: any LogBus = InMemoryLogBus(),
        handleRoute: @escaping @Sendable (Route, Request, BasicRequestContext) async throws -> Response
    ) -> Application<CallbackResponder<BasicRequestContext>> {
        let requestLogger = RequestLogMiddleware(logBus: logBus)
        let responder = CallbackResponder<BasicRequestContext> { request, context in
            try await requestLogger.handle(request, context: context) { request, context in
                guard let host = try routeHost(for: request) else {
                    return Response(status: .notFound)
                }
                switch try await resolveRoute(host: host, path: request.uri.path) {
                case .matched(let route):
                    return try await handleRoute(route, request, context)

                case .stopped:
                    return Response(status: .serviceUnavailable)

                case .notFound, .ambiguous:
                    return Response(status: .notFound)
                }
            }
        }
        return Application(
            responder: responder,
            configuration: .init(address: .hostname(address, port: port))
        )
    }
    private static func routeHost(for request: Request) throws -> RouteHost? {
        guard let authority = request.head.authority else { return nil }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard let name = parts.first, parts.count <= maximumAuthorityParts else { return nil }
        if parts.count > 1 {
            let port = parts[1]
            guard !port.isEmpty, port.allSatisfy({ ("0"..."9").contains($0) }) else { return nil }
        }
        do {
            // RouteHost は DNS 名を扱うため、HTTP の authority に付く port を外します。
            return try RouteHost(String(name))
        } catch RouteHost.ValidationError.invalidHost {
            return nil
        }
    }

}
