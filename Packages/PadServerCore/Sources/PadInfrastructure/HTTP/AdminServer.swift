import Hummingbird
import NIOCore
import PadDomain

public struct AdminRequestContext: RequestContext, RemoteAddressRequestContext {
    public var coreContext: CoreRequestContextStorage
    public let remoteAddress: SocketAddress?

    public init(source: Source) {
        self.coreContext = .init(source: source)
        self.remoteAddress = source.channel.remoteAddress
    }

    public var clientAddress: ClientAddress? {
        Self.clientAddress(from: self.remoteAddress)
    }

    static func clientAddress(from remoteAddress: SocketAddress?) -> ClientAddress? {
        guard let remoteAddress else {
            return nil
        }

        switch remoteAddress.protocol {
        case .inet, .inet6:
            guard let address = remoteAddress.ipAddress else {
                return nil
            }
            return ClientAddress(address)

        default:
            return nil
        }
    }
}

public enum AdminServerError: Error, Equatable, Sendable {
    case invalidPort(Int)
    case portsMustBeDistinct
}

public enum AdminServer {
    private enum Constants {
        // 管理接続は端末の network interface で受け、認可は後続の middleware が行う。
        static let bindHost = "0.0.0.0"
        // 管理と配信の待ち受けは固定 port を使うため、割り当て先を取得できない 0 は許可しない。
        static let minimumPort = 1
        static let maximumPort = Int(UInt16.max)
    }

    public static func makeApplication(
        adminPort: Int,
        deliveryPort: Int,
        configureRoutes: (Router<AdminRequestContext>) -> Void = { _ in
            // 管理 endpoint は後続 Issue の責務として追加する。
        }
    ) throws -> Application<RouterResponder<AdminRequestContext>> {
        guard Self.isValidPort(adminPort) else {
            throw AdminServerError.invalidPort(adminPort)
        }
        guard Self.isValidPort(deliveryPort) else {
            throw AdminServerError.invalidPort(deliveryPort)
        }
        guard adminPort != deliveryPort else {
            throw AdminServerError.portsMustBeDistinct
        }

        let router = Router(context: AdminRequestContext.self)
        configureRoutes(router)
        return Application(
            responder: router.buildResponder(),
            configuration: .init(address: .hostname(Constants.bindHost, port: adminPort))
        )
    }

    private static func isValidPort(_ port: Int) -> Bool {
        (Constants.minimumPort...Constants.maximumPort).contains(port)
    }
}
