/// guest の Docker の応答を, 転送した port への ping で確かめる.
public actor GuestDockerReadiness {
    private let guestPort: UInt16
    private let openPort: @Sendable (_ guestPort: UInt16) async throws -> UInt16
    private let makeProbe: @Sendable (_ hostPort: UInt16) async throws -> @Sendable () async throws -> Void
    private var probe: (@Sendable () async throws -> Void)?

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
            })
    }

    init(
        guestPort: UInt16,
        openPort: @escaping @Sendable (_ guestPort: UInt16) async throws -> UInt16,
        makeProbe: @escaping @Sendable (_ hostPort: UInt16) async throws -> @Sendable () async throws -> Void
    ) {
        self.guestPort = guestPort
        self.openPort = openPort
        self.makeProbe = makeProbe
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

    private func readyProbe() async throws -> @Sendable () async throws -> Void {
        if let probe { return probe }
        let created = try await makeProbe(openPort(guestPort))
        probe = created
        return created
    }
}
