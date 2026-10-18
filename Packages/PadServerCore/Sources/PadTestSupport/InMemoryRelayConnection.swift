import PadApplication
import PadDomain

public actor InMemoryRelayConnection: RelayConnection {
    private let stateOnStart: RelayConnectionState
    private var currentState: RelayConnectionState = .disconnected

    public private(set) var startedConfig: RelayConfig?

    public init(stateOnStart: RelayConnectionState = .connected) {
        self.stateOnStart = stateOnStart
    }

    public func state() -> RelayConnectionState {
        currentState
    }

    public func start(_ config: RelayConfig) {
        startedConfig = config
        currentState = stateOnStart
    }

    public func stop() {
        currentState = .disconnected
    }
}
