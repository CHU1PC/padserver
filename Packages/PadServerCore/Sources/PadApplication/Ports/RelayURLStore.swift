import Foundation

public protocol RelayURLStore: Sendable {
    func relayURL() async throws -> URL?
    func setRelayURL(_ url: URL) async throws
}
