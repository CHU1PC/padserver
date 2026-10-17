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
    case portsMustBeDistinct
    case invalidTailnetAddress
}

public enum AdminServer {
    public static func makeApplication(
        adminPort: Int,
        deliveryPort: Int,
        tailnetAddress: String,
        configureRoutes: (Router<AdminRequestContext>) -> Void = { _ in
            // 管理 endpoint は後続 Issue の責務として追加する。
        }
    ) throws -> Application<RouterResponder<AdminRequestContext>> {
        guard adminPort != deliveryPort else {
            throw AdminServerError.portsMustBeDistinct
        }
        guard ClientAddress(tailnetAddress).isInTailnet else {
            throw AdminServerError.invalidTailnetAddress
        }

        // 接続元と token による認可は #70 の middleware が行う。
        let router = Router(context: AdminRequestContext.self)
        configureRoutes(router)
        return Application(
            responder: router.buildResponder(),
            configuration: .init(address: .hostname(tailnetAddress, port: adminPort))
        )
    }
}
