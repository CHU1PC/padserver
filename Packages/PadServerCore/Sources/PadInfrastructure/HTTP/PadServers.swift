import Hummingbird
import PadApplication

public struct PadServerPorts: Sendable {
    public let delivery: Int
    public let admin: Int
    public let tailnetAddress: String

    public init(delivery: Int, admin: Int, tailnetAddress: String) {
        self.delivery = delivery
        self.admin = admin
        self.tailnetAddress = tailnetAddress
    }
}

public struct PadServers: Sendable {
    private let ports: PadServerPorts
    private let storage: any ProjectStorage
    private let secretStore: any SecretStore
    private let idGenerator: any IDGenerator
    private let logBus: any LogBus

    public init(
        ports: PadServerPorts,
        storage: any ProjectStorage,
        secretStore: any SecretStore,
        idGenerator: any IDGenerator,
        logBus: any LogBus
    ) {
        self.ports = ports
        self.storage = storage
        self.secretStore = secretStore
        self.idGenerator = idGenerator
        self.logBus = logBus
    }

    /// 配信 (loopback と tailnet) と管理の待ち受けを同時に動かし, どれかが終わるか失敗したら全部を止めます.
    public func run() async throws {
        let delivery = makeDeliveryApplication()
        let tailnetDelivery = makeTailnetDeliveryApplication()
        let admin = try makeAdminApplication()
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask { try await delivery.runService() }
            group.addTask { try await tailnetDelivery.runService() }
            group.addTask { try await admin.runService() }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    func makeDeliveryApplication() -> Application<CallbackResponder<BasicRequestContext>> {
        makeDeliveryApplication(address: "127.0.0.1")
    }

    func makeTailnetDeliveryApplication() -> Application<CallbackResponder<BasicRequestContext>> {
        makeDeliveryApplication(address: ports.tailnetAddress)
    }

    private func makeDeliveryApplication(address: String) -> Application<CallbackResponder<BasicRequestContext>> {
        let staticFiles = StaticFileResponder(storage: storage)
        return ServingServer.makeApplication(
            address: address,
            port: ports.delivery,
            resolveRoute: ResolveRoute(storage: storage),
            logBus: logBus
        ) { route, request, context in
            switch route.target {
            case .staticSite:
                return try await staticFiles.respond(to: request, route: route, context: context)

            case .container:
                // container への転送は guest の組み立て (M4-23) まで繋がらないため 502 を返します.
                return Response(status: .badGateway)
            }
        }
    }

    func makeAdminApplication() throws -> Application<RouterResponder<AdminRequestContext>> {
        let controllers = (
            deploy: DeployController(
                planDeployment: PlanDeployment(storage: storage),
                commitDeployment: CommitDeployment(storage: storage, idGenerator: idGenerator)),
            blob: BlobController(storage: storage),
            project: ProjectController(
                listProjects: ListProjects(storage: storage), setProjectState: SetProjectState(storage: storage)),
            log: LogController(logBus: logBus)
        )
        return try AdminServer.makeApplication(
            adminPort: ports.admin,
            deliveryPort: ports.delivery,
            tailnetAddress: ports.tailnetAddress,
            authorizeAdmin: AuthorizeAdmin(secretStore: secretStore)
        ) { router in
            router.add(middleware: AdminErrorMiddleware())
            controllers.deploy.addRoutes(to: router)
            controllers.blob.addRoutes(to: router)
            controllers.project.addRoutes(to: router)
            controllers.log.addRoutes(to: router)
        }
    }
}
