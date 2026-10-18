import Foundation
import PadDomain

protocol RelayTunnel: Sendable {
    var stateChanges: AsyncStream<RelayConnectionState> { get }
    func start(_ config: RelayConfig) async
    func stop() async
    func send(_ message: RelaySocketMessage) async throws
    func receivedMessageCount() async -> Int
}

extension RelayClient: RelayTunnel {}

public actor RelayReconnector {
    private static let baseDelaySeconds = 0.5
    private static let maxDelaySeconds = 30.0
    private static let maxBackoffExponent = 6
    private static let stableConnectionSeconds = 10
    private static let pingIntervalSeconds = 20
    private static let pongTimeoutSeconds = 10
    static let jitterRange = 0.5...1.0
    private static let pingText = "ping"

    private let tunnel: any RelayTunnel
    private let clock: any Clock<Duration>
    private let jitter: @Sendable () -> Double
    private var config: RelayConfig?
    private var state: RelayConnectionState = .disconnected
    private var attempt = 0
    private var observeTask: Task<Void, Never>?
    private var reconnectTask: Task<Void, Never>?
    private var keepaliveTask: Task<Void, Never>?
    private var stableTask: Task<Void, Never>?

    public init(client: RelayClient) {
        self.init(tunnel: client)
    }

    init(
        tunnel: any RelayTunnel,
        clock: any Clock<Duration> = ContinuousClock(),
        jitter: @escaping @Sendable () -> Double = { Double.random(in: RelayReconnector.jitterRange) }
    ) {
        self.tunnel = tunnel
        self.clock = clock
        self.jitter = jitter
    }

    deinit {
        observeTask?.cancel()
    }

    public func start(_ config: RelayConfig) async {
        cancelTasks()
        self.config = config
        attempt = 0
        observeIfNeeded()
        await tunnel.start(config)
    }

    public func stop() async {
        cancelTasks()
        config = nil
        attempt = 0
        await tunnel.stop()
    }

    public func foregrounded() async {
        switch state {
        case .reconnecting:
            attempt = 0
            reconnect(after: nil)

        case .connected:
            if await !probe(), state == .connected {
                dropConnection()
            }

        case .disconnected, .connecting, .replaced, .unauthorized:
            break
        }
    }

    private func observeIfNeeded() {
        guard observeTask == nil else { return }
        let changes = tunnel.stateChanges
        observeTask = Task { [weak self] in
            for await state in changes {
                await self?.handle(state)
            }
        }
    }

    private func handle(_ newState: RelayConnectionState) {
        state = newState
        switch newState {
        case .connected:
            beginConnectionTasks()

        case .reconnecting:
            endConnectionTasks()
            reconnect(after: nextDelay())

        case .replaced, .unauthorized, .disconnected:
            cancelTasks()

        case .connecting:
            break
        }
    }

    private func nextDelay() -> Duration {
        let exponent = min(attempt, Self.maxBackoffExponent)
        let base = min(Self.maxDelaySeconds, Self.baseDelaySeconds * Double(1 << exponent))
        attempt += 1
        return .seconds(base * jitter())
    }

    private func reconnect(after delay: Duration?) {
        guard let config else { return }
        reconnectTask?.cancel()
        reconnectTask = Task { [clock, tunnel] in
            if let delay {
                do {
                    try await clock.sleep(for: delay)
                } catch {
                    return
                }
            }
            await tunnel.start(config)
        }
    }

    private func beginConnectionTasks() {
        endConnectionTasks()
        stableTask = Task { [clock] in
            do {
                try await clock.sleep(for: .seconds(Self.stableConnectionSeconds))
            } catch {
                return
            }
            markStable()
        }
        keepaliveTask = Task { await self.keepalive() }
    }

    private func endConnectionTasks() {
        keepaliveTask?.cancel()
        keepaliveTask = nil
        stableTask?.cancel()
        stableTask = nil
    }

    private func cancelTasks() {
        endConnectionTasks()
        reconnectTask?.cancel()
        reconnectTask = nil
    }

    private func markStable() {
        attempt = 0
    }

    private func keepalive() async {
        while !Task.isCancelled {
            guard await probe() else {
                dropConnection()
                return
            }
            do {
                try await clock.sleep(for: .seconds(Self.pingIntervalSeconds - Self.pongTimeoutSeconds))
            } catch {
                return
            }
        }
    }

    private func probe() async -> Bool {
        let before = await tunnel.receivedMessageCount()
        do {
            try await tunnel.send(.text(Self.pingText))
            try await clock.sleep(for: .seconds(Self.pongTimeoutSeconds))
        } catch is CancellationError {
            return true
        } catch {
            return false
        }
        return await tunnel.receivedMessageCount() > before
    }

    private func dropConnection() {
        endConnectionTasks()
        reconnect(after: nil)
    }
}
