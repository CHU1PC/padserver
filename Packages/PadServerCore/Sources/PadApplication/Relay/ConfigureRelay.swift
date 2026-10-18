import PadDomain

public struct ConfigureRelay: Sendable {
    private let secretStore: any SecretStore
    private let urlStore: any RelayURLStore

    public init(secretStore: any SecretStore, urlStore: any RelayURLStore) {
        self.secretStore = secretStore
        self.urlStore = urlStore
    }

    /// 検証に通った設定だけを保存します。token を先に保存し、URL の保存に失敗したら前の token に戻します (戻せなければ戻す側の error を投げます)。
    public func callAsFunction(url: String, token: String) async throws {
        let config = try RelayConfig(url: url, token: token)
        let previousToken = try await secretStore.relayToken()

        try await secretStore.setRelayToken(config.token)
        do {
            try await urlStore.setRelayURL(config.url)
        } catch {
            if let previousToken {
                try await secretStore.setRelayToken(previousToken)
            }
            throw error
        }
    }

    /// URL と token の両方が保存されているときだけ設定を返します。
    public func load() async throws -> RelayConfig? {
        guard let url = try await urlStore.relayURL(), let token = try await secretStore.relayToken() else {
            return nil
        }
        return try RelayConfig(url: url.absoluteString, token: token.value)
    }
}
