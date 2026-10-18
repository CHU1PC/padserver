import PadDomain

public protocol RelayConnection: Sendable {
    func state() async -> RelayConnectionState
    func start(_ config: RelayConfig) async
    func stop() async
}
