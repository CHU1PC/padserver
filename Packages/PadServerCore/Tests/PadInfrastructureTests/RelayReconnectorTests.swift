import Foundation
import PadDomain
import Synchronization
import Testing

@testable import PadInfrastructure

private let neverSeconds = 60
private let reconnectDelayCeilingSeconds = 5

private final class ManualClock: Clock, Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let id: Int
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct State {
        var now = Instant(offset: .zero)
        var nextID = 0
        var sleepers: [Sleeper] = []
    }

    private enum Registration {
        case registered
        case resumeNow
        case cancelled
    }

    private let state = Mutex(State())

    var now: Instant {
        state.withLock { $0.now }
    }

    var minimumResolution: Duration { .zero }

    var sleeperCount: Int {
        state.withLock { $0.sleepers.count }
    }

    var nextDelay: Duration? {
        state.withLock { current in
            current.sleepers.map(\.deadline).min().map { current.now.duration(to: $0) }
        }
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = state.withLock { current in
            current.nextID += 1
            return current.nextID
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let registration = state.withLock { current -> Registration in
                    if Task.isCancelled { return .cancelled }
                    if deadline <= current.now { return .resumeNow }
                    current.sleepers.append(Sleeper(id: id, deadline: deadline, continuation: continuation))
                    return .registered
                }
                switch registration {
                case .registered: break
                case .resumeNow: continuation.resume()
                case .cancelled: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let cancelled = state.withLock { current -> Sleeper? in
                guard let index = current.sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                return current.sleepers.remove(at: index)
            }
            cancelled?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        let due = state.withLock { current -> [Sleeper] in
            current.now = current.now.advanced(by: duration)
            let due = current.sleepers.filter { $0.deadline <= current.now }
            current.sleepers.removeAll { $0.deadline <= current.now }
            return due
        }
        for sleeper in due {
            sleeper.continuation.resume()
        }
    }

    func waitForOnlyReconnectSleeper() async {
        while sleeperCount != 1 || (nextDelay ?? .seconds(neverSeconds)) >= .seconds(reconnectDelayCeilingSeconds) {
            await Task.yield()
        }
    }

    func waitForSleepers(_ count: Int) async {
        while sleeperCount < count {
            await Task.yield()
        }
    }
}

private actor FakeTunnel: RelayTunnel {
    nonisolated let stateChanges: AsyncStream<RelayConnectionState>
    private let continuation: AsyncStream<RelayConnectionState>.Continuation
    private var outcomes: [[RelayConnectionState]]
    private var replyToPing: Bool
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var pingCount = 0
    private var receivedCount = 0

    init(outcomes: [[RelayConnectionState]], replyToPing: Bool = true) {
        (stateChanges, continuation) = AsyncStream.makeStream()
        self.outcomes = outcomes
        self.replyToPing = replyToPing
    }

    func start(_ config: RelayConfig) {
        startCount += 1
        guard !outcomes.isEmpty else { return }
        for state in outcomes.removeFirst() {
            continuation.yield(state)
        }
    }

    func stop() {
        stopCount += 1
        continuation.yield(.disconnected)
    }

    func send(_ message: RelaySocketMessage) throws {
        guard case .text("ping") = message else { return }
        pingCount += 1
        if replyToPing { receivedCount += 1 }
    }

    func receivedMessageCount() -> Int {
        receivedCount
    }

    func emit(_ state: RelayConnectionState) {
        continuation.yield(state)
    }

    func waitForStarts(_ count: Int) async {
        while startCount < count {
            await Task.yield()
        }
    }

    func waitForPings(_ count: Int) async {
        while pingCount < count {
            await Task.yield()
        }
    }
}

private let failedOpen: [RelayConnectionState] = [.connecting, .reconnecting]
private let successfulOpen: [RelayConnectionState] = [.connecting, .connected]

private func makeConfig() throws -> RelayConfig {
    try RelayConfig(url: "wss://relay.example.com", token: "example-token")
}

private func makeReconnector(
    _ tunnel: FakeTunnel, clock: ManualClock, jitter: @escaping @Sendable () -> Double = { 1.0 }
) -> RelayReconnector {
    RelayReconnector(tunnel: tunnel, clock: clock, jitter: jitter)
}

private func settle() async throws {
    try await Task.sleep(for: .milliseconds(100))
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorDoublesTheDelayUpToThirtySeconds() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: Array(repeating: failedOpen, count: 9))
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())

    var delays: [Duration] = []
    for index in 1...8 {
        await clock.waitForSleepers(1)
        let delay = try #require(clock.nextDelay)
        delays.append(delay)
        clock.advance(by: delay)
        await tunnel.waitForStarts(index + 1)
    }
    #expect(delays == [0.5, 1, 2, 4, 8, 16, 30, 30].map { Duration.seconds($0) })
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorAppliesJitterToTheDelay() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [failedOpen])
    let reconnector = makeReconnector(tunnel, clock: clock) { 0.5 }

    await reconnector.start(try makeConfig())
    await clock.waitForSleepers(1)

    #expect(clock.nextDelay == .seconds(0.25))
    await reconnector.stop()
}

@Test(arguments: [RelayConnectionState.unauthorized, .replaced])
func relayReconnectorDoesNotRetryAfterTerminalStates(state: RelayConnectionState) async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [[.connecting, state]])
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    try await settle()

    #expect(clock.sleeperCount == 0)
    #expect(await tunnel.startCount == 1)
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorResetsTheDelayAfterTenSecondsConnected() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [failedOpen, failedOpen, successfulOpen])
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(0.5))
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(1))
    await tunnel.waitForStarts(3)
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(10))
    await clock.waitForSleepers(1)
    try await settle()
    await tunnel.emit(.reconnecting)
    await clock.waitForOnlyReconnectSleeper()

    #expect(clock.nextDelay == .seconds(0.5))
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorKeepsTheDelayWhenTheConnectionDropsQuickly() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [failedOpen, successfulOpen])
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(0.5))
    await tunnel.waitForStarts(2)
    await tunnel.waitForPings(1)
    await tunnel.emit(.reconnecting)
    await clock.waitForOnlyReconnectSleeper()

    #expect(clock.nextDelay == .seconds(1))
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorPingsRightAfterConnectingAndEveryTwentySeconds() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [successfulOpen])
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    await tunnel.waitForPings(1)
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(10))
    await clock.waitForSleepers(1)
    clock.advance(by: .seconds(10))
    await tunnel.waitForPings(2)

    #expect(await tunnel.startCount == 1)
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorReconnectsWhenNoPongArrivesWithinTenSeconds() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [successfulOpen, successfulOpen], replyToPing: false)
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    await tunnel.waitForPings(1)
    await clock.waitForSleepers(2)
    clock.advance(by: .seconds(10))
    await tunnel.waitForStarts(2)

    #expect(await tunnel.startCount == 2)
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorForegroundSkipsTheWaitAndResetsTheDelay() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: Array(repeating: failedOpen, count: 5))
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    for index in 1...3 {
        await clock.waitForSleepers(1)
        clock.advance(by: try #require(clock.nextDelay))
        await tunnel.waitForStarts(index + 1)
    }
    await clock.waitForSleepers(1)
    await reconnector.foregrounded()
    await tunnel.waitForStarts(5)
    await clock.waitForSleepers(1)

    #expect(clock.nextDelay == .seconds(0.5))
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorForegroundProbesAConnectedTunnelAndReconnectsWithoutPong() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [successfulOpen, successfulOpen], replyToPing: false)
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    await tunnel.waitForPings(1)
    await clock.waitForSleepers(2)
    let foreground = Task { await reconnector.foregrounded() }
    await tunnel.waitForPings(2)
    await clock.waitForSleepers(3)
    clock.advance(by: .seconds(10))
    await foreground.value
    await tunnel.waitForStarts(2)

    #expect(await tunnel.pingCount == 2)
    await reconnector.stop()
}

@Test(.timeLimit(.minutes(1)))
func relayReconnectorStopCancelsPendingReconnect() async throws {
    let clock = ManualClock()
    let tunnel = FakeTunnel(outcomes: [failedOpen])
    let reconnector = makeReconnector(tunnel, clock: clock)

    await reconnector.start(try makeConfig())
    await clock.waitForSleepers(1)
    await reconnector.stop()
    try await settle()

    #expect(clock.sleeperCount == 0)
    #expect(await tunnel.startCount == 1)
    #expect(await tunnel.stopCount == 1)
}
