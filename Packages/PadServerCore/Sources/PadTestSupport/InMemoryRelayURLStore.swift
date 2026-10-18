import Foundation
import PadApplication

public actor InMemoryRelayURLStore: RelayURLStore {
    private var currentURL: URL?

    public init() {
        // 明示した初期化子で公開 API を安定させます。
    }

    public func relayURL() -> URL? {
        currentURL
    }

    public func setRelayURL(_ url: URL) {
        currentURL = url
    }
}
