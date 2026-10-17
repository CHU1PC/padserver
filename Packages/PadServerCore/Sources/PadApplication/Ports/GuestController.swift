import PadDomain

public protocol GuestController: Sendable {
    func state() async -> GuestState
    func start() async throws
    func stop() async throws
}
