@testable import PadGuest
import Synchronization
import Testing

@available(macOS 15, iOS 18, *)
private final class VirtualClock: Clock {
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

    private let current = Mutex(Duration.zero)

    var now: Instant { Instant(offset: current.withLock { $0 }) }
    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        current.withLock { $0 = max($0, deadline.offset) }
        await Task.yield()
    }
}

private enum Constants {
    static let thirtySeconds = 30
    static let timeout = Duration.seconds(thirtySeconds)
    static let pollInterval = Duration.seconds(1)
    static let respondsAfterPolls = 3
}

private struct LaunchFailure: Error, Equatable {}

private actor Calls {
    private(set) var launches = 0
    private(set) var quits = 0
    private(set) var cleanups = 0
    private(set) var probes = 0

    func launch() { launches += 1 }
    func quit() { quits += 1 }
    func cleanup() { cleanups += 1 }
    func probe() -> Int {
        probes += 1
        return probes
    }
}

@available(macOS 15, iOS 18, *)
private func makeController(
    calls: Calls,
    launchFails: Bool = false,
    respondsAfterPolls: Int?
) -> QEMUGuestController {
    QEMUGuestController(
        launch: {
            await calls.launch()
            if launchFails { throw LaunchFailure() }
            return { await calls.cleanup() }
        },
        quit: { await calls.quit() },
        isDockerReady: {
            let count = await calls.probe()
            guard let respondsAfterPolls else { return false }
            return count >= respondsAfterPolls
        },
        clock: VirtualClock(),
        readinessTimeout: Constants.timeout,
        pollInterval: Constants.pollInterval
    )
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerBecomesReadyWhenDockerResponds() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: Constants.respondsAfterPolls)

    #expect(await controller.state() == .stopped)
    try await controller.start()

    #expect(await controller.state() == .ready)
    #expect(await calls.launches == 1)
    #expect(await calls.probes == Constants.respondsAfterPolls)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerFailsWhenDockerDoesNotRespondInTime() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: nil)

    await #expect(throws: QEMUGuestController.ControllerError.readinessTimedOut) {
        try await controller.start()
    }

    #expect(await controller.state() == .failed)
    #expect(await calls.probes > 1)
    #expect(await calls.quits == 0)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerFailsWhenLaunchFails() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, launchFails: true, respondsAfterPolls: 1)

    await #expect(throws: LaunchFailure()) {
        try await controller.start()
    }

    #expect(await controller.state() == .failed)
    #expect(await calls.probes == 0)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerStopsByQuittingQEMU() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: 1)
    try await controller.start()

    try await controller.stop()

    #expect(await controller.state() == .stopped)
    #expect(await calls.quits == 1)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerRejectsStartWhileRunning() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: 1)
    try await controller.start()

    await #expect(throws: QEMUGuestController.ControllerError.notStopped) {
        try await controller.start()
    }

    #expect(await controller.state() == .ready)
    #expect(await calls.launches == 1)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerQuitsAfterReadinessTimeout() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: nil)
    await #expect(throws: QEMUGuestController.ControllerError.readinessTimedOut) {
        try await controller.start()
    }

    try await controller.stop()

    #expect(await controller.state() == .stopped)
    #expect(await calls.quits == 1)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerRunsLaunchCleanupAfterBecomingReady() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: Constants.respondsAfterPolls)

    try await controller.start()

    #expect(await calls.cleanups == 1)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerRunsLaunchCleanupAfterReadinessTimeout() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, respondsAfterPolls: nil)

    await #expect(throws: QEMUGuestController.ControllerError.readinessTimedOut) {
        try await controller.start()
    }

    #expect(await calls.cleanups == 1)
}

@available(macOS 15, iOS 18, *)
@Test(.timeLimit(.minutes(1)))
func guestControllerSkipsLaunchCleanupWhenLaunchFails() async throws {
    let calls = Calls()
    let controller = makeController(calls: calls, launchFails: true, respondsAfterPolls: 1)

    await #expect(throws: LaunchFailure()) {
        try await controller.start()
    }

    #expect(await calls.cleanups == 0)
}
