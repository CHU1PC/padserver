/// guest の Docker の応答を, 転送した port への ping で確かめる.
public actor GuestDockerReadiness {
    private let guestPort: UInt16
    private let openPort: @Sendable (_ guestPort: UInt16) async throws -> UInt16
    private let makeProbe: @Sendable (_ hostPort: UInt16) async throws -> @Sendable () async throws -> Void
    private let makeUsages:
        @Sendable (_ hostPort: UInt16) async throws -> @Sendable () async throws -> [String: ContainerUsage]
    private var hostPort: UInt16?
    private var probe: (@Sendable () async throws -> Void)?
    private var usages: (@Sendable () async throws -> [String: ContainerUsage])?

    public init(
        guestPort: UInt16,
        forwarder: PortForwarder,
        credentials: @escaping @Sendable () async throws -> GuestCredentials
    ) {
        self.init(
            guestPort: guestPort,
            openPort: { try forwarder.open(guestPort: $0) },
            makeProbe: { hostPort in
                let client = try await DockerClient(hostPort: hostPort, credentials: credentials())
                return { try await client.ping() }
            },
            makeUsages: { hostPort in
                let client = try await DockerClient(hostPort: hostPort, credentials: credentials())
                return { try await client.projectUsages() }
            })
    }

    init(
        guestPort: UInt16,
        openPort: @escaping @Sendable (_ guestPort: UInt16) async throws -> UInt16,
        makeProbe: @escaping @Sendable (_ hostPort: UInt16) async throws -> @Sendable () async throws -> Void,
        makeUsages:
            @escaping @Sendable (_ hostPort: UInt16) async throws
            -> @Sendable () async throws -> [String: ContainerUsage]
    ) {
        self.guestPort = guestPort
        self.openPort = openPort
        self.makeProbe = makeProbe
        self.makeUsages = makeUsages
    }

    /// monitor がまだ繋がらない間や ping が通らない間は false を返す.
    public func isReady() async -> Bool {
        do {
            let probe = try await readyProbe()
            try await probe()
            return true
        } catch {
            return false
        }
    }

    /// guest がまだ準備できていないときは, 転送や読み取りの失敗をそのまま投げる.
    public func projectUsages() async throws -> [String: ContainerUsage] {
        if let usages { return try await usages() }
        let created = try await makeUsages(forwardedPort())
        usages = created
        return try await created()
    }

    private func forwardedPort() async throws -> UInt16 {
        if let hostPort { return hostPort }
        let opened = try await openPort(guestPort)
        hostPort = opened
        return opened
    }

    private func readyProbe() async throws -> @Sendable () async throws -> Void {
        if let probe { return probe }
        let created = try await makeProbe(forwardedPort())
        probe = created
        return created
    }
}
