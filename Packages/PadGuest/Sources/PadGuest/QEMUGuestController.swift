@available(macOS 13, iOS 16, *)
public actor QEMUGuestController {
    public enum State: String, Sendable {
        case stopped
        case starting
        case ready
        case failed
    }

    public enum ControllerError: Error, Equatable, Sendable {
        case notStopped
        case readinessTimedOut
    }

    private enum Constants {
        static let pollInterval = Duration.seconds(1)
    }

    private let launch: @Sendable () async throws -> Void
    private let quit: @Sendable () async throws -> Void
    private let isDockerReady: @Sendable () async -> Bool
    private let clock: any Clock<Duration>
    private let readinessTimeout: Duration
    private let pollInterval: Duration
    private var current = State.stopped

    public init(
        runner: QEMURunner,
        monitor: QEMUMonitor,
        disk: GuestDisk,
        diskSizeBytes: UInt64,
        arguments: @escaping @Sendable (_ diskPath: String) -> QEMUArguments,
        additionalArguments: [String] = [],
        isDockerReady: @escaping @Sendable () async -> Bool,
        readinessTimeout: Duration
    ) {
        self.init(
            launch: {
                let diskURL = try disk.createIfNeeded(sizeBytes: diskSizeBytes)
                try runner.start(arguments: arguments(diskURL.path), additionalArguments: additionalArguments)
            },
            quit: { try monitor.quit() },
            isDockerReady: isDockerReady,
            clock: ContinuousClock(),
            readinessTimeout: readinessTimeout,
            pollInterval: Constants.pollInterval
        )
    }

    init(
        launch: @escaping @Sendable () async throws -> Void,
        quit: @escaping @Sendable () async throws -> Void,
        isDockerReady: @escaping @Sendable () async -> Bool,
        clock: any Clock<Duration>,
        readinessTimeout: Duration,
        pollInterval: Duration
    ) {
        self.launch = launch
        self.quit = quit
        self.isDockerReady = isDockerReady
        self.clock = clock
        self.readinessTimeout = readinessTimeout
        self.pollInterval = pollInterval
    }

    public func state() -> State {
        current
    }

    public func start() async throws {
        guard current == .stopped else { throw ControllerError.notStopped }
        current = .starting
        do {
            try await launch()
            let responded = try await Self.waitUntilReady(
                clock: clock, timeout: readinessTimeout, interval: pollInterval, isReady: isDockerReady)
            guard responded else { throw ControllerError.readinessTimedOut }
            current = .ready
        } catch {
            current = .failed
            throw error
        }
    }

    public func stop() async throws {
        guard current != .stopped else { return }
        do {
            try await quit()
        } catch {
            current = .failed
            throw error
        }
        current = .stopped
    }

    private static func waitUntilReady<C: Clock<Duration>>(
        clock: C,
        timeout: Duration,
        interval: Duration,
        isReady: @Sendable () async -> Bool
    ) async throws -> Bool {
        let deadline = clock.now.advanced(by: timeout)
        while true {
            if await isReady() { return true }
            if clock.now >= deadline { return false }
            try await clock.sleep(for: interval)
        }
    }
}
