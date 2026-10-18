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
    private static let shareLinkPathPrefix = "/s/"

    private let ports: PadServerPorts
    private let storage: any ProjectStorage
    private let secretStore: any SecretStore
    private let idGenerator: any IDGenerator
    private let logBus: any LogBus
    private let fileStore: any FileStore
    private let linkStore: any ShareLinkStore
    private let timeSource: any TimeSource

    public init(
        ports: PadServerPorts,
        storage: any ProjectStorage,
        secretStore: any SecretStore,
        idGenerator: any IDGenerator,
        logBus: any LogBus,
        fileStore: any FileStore,
        linkStore: any ShareLinkStore,
        timeSource: any TimeSource
    ) {
        self.ports = ports
        self.storage = storage
        self.secretStore = secretStore
        self.idGenerator = idGenerator
        self.logBus = logBus
        self.fileStore = fileStore
        self.linkStore = linkStore
        self.timeSource = timeSource
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
        let shareLinks = ShareLinkResponder(fileStore: fileStore, linkStore: linkStore, timeSource: timeSource)
        return ServingServer.makeApplication(
            address: address,
            port: ports.delivery,
            resolveRoute: ResolveRoute(storage: storage),
            logBus: logBus,
            handlePublicPath: { request, _ in
                guard request.uri.path.hasPrefix(Self.shareLinkPathPrefix) else { return nil }
                let secret = request.uri.path.dropFirst(Self.shareLinkPathPrefix.count)
                guard !secret.isEmpty, !secret.contains("/") else { return Response(status: .notFound) }
                return try await shareLinks.respond(to: request, secret: String(secret))
            },
            handleRoute: { route, request, context in
                switch route.target {
                case .staticSite:
                    return try await staticFiles.respond(to: request, route: route, context: context)

                case .container:
                    // container への転送は guest の組み立て (M4-23) まで繋がらないため 502 を返します.
                    return Response(status: .badGateway)
                }
            }
        )
    }

    func addAdminRoutes(to router: Router<AdminRequestContext>) {
        let manageFiles = ManageFiles(fileStore: fileStore, linkStore: linkStore)
        let controllers = (
            deploy: DeployController(
                planDeployment: PlanDeployment(storage: storage),
                commitDeployment: CommitDeployment(storage: storage, idGenerator: idGenerator)),
            blob: BlobController(storage: storage),
            project: ProjectController(
                listProjects: ListProjects(storage: storage), setProjectState: SetProjectState(storage: storage)),
            log: LogController(logBus: logBus),
            fileTransfer: FileTransferController(storeFile: StoreFile(store: fileStore)),
            fileList: FileListController(manageFiles: manageFiles),
            shareLink: ShareLinkController(
                shareLinks: ShareLinks(
                    fileStore: fileStore, linkStore: linkStore, timeSource: timeSource, idGenerator: idGenerator),
                manageFiles: manageFiles, linkStore: linkStore, timeSource: timeSource)
        )
        router.add(middleware: AdminErrorMiddleware())
        controllers.deploy.addRoutes(to: router)
        controllers.blob.addRoutes(to: router)
        controllers.project.addRoutes(to: router)
        controllers.log.addRoutes(to: router)
        controllers.fileTransfer.addRoutes(to: router)
        controllers.fileList.addRoutes(to: router)
        controllers.shareLink.addRoutes(to: router)
    }

    func makeAdminApplication() throws -> Application<RouterResponder<AdminRequestContext>> {
        try AdminServer.makeApplication(
            adminPort: ports.admin,
            deliveryPort: ports.delivery,
            tailnetAddress: ports.tailnetAddress,
            authorizeAdmin: AuthorizeAdmin(secretStore: secretStore)
        ) { router in
            addAdminRoutes(to: router)
        }
    }
}
