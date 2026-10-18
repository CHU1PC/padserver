import Testing

@testable import PadDomain

@Test(arguments: ["wss://relay.example.com", "https://relay.example.com", "wss://relay.example.com:8443/base"])
func relayConfigAcceptsTLSURLWithHost(url: String) throws {
    let config = try RelayConfig(url: url, token: "example-token")
    #expect(config.url.absoluteString == url)
    #expect(config.token.value == "example-token")
}

@Test(arguments: ["", "not a url", "relay.example.com", "wss://", "wss:///path"])
func relayConfigRejectsURLWithoutHost(url: String) {
    #expect(throws: RelayConfig.ValidationError.invalidURL) {
        try RelayConfig(url: url, token: "example-token")
    }
}

@Test(arguments: ["http://relay.example.com", "ws://relay.example.com", "ftp://relay.example.com"])
func relayConfigRejectsNonTLSScheme(url: String) {
    #expect(throws: RelayConfig.ValidationError.unsupportedScheme) {
        try RelayConfig(url: url, token: "example-token")
    }
}

@Test(arguments: ["", "   ", "\n"])
func relayConfigRejectsBlankToken(token: String) {
    #expect(throws: RelayConfig.ValidationError.emptyToken) {
        try RelayConfig(url: "wss://relay.example.com", token: token)
    }
}

@Test func relayConfigOutputsNeverContainToken() throws {
    let secret = "secret-token-value"
    let config = try RelayConfig(url: "wss://relay.example.com", token: secret)
    var dumped = ""
    dump(config, to: &dumped)
    dump(config.token, to: &dumped)

    let outputs = [
        String(describing: config), String(reflecting: config),
        String(describing: config.token), String(reflecting: config.token),
        "\(config)", dumped,
    ]
    for output in outputs {
        #expect(!output.contains(secret))
    }
    #expect(String(describing: config.token) == "RelayToken(<redacted>)")
    #expect(String(describing: config).contains("wss://relay.example.com"))
}

@Test func relayConnectionStateIsComparableAndPrintable() {
    #expect(RelayConnectionState.connected == .connected)
    #expect(RelayConnectionState.replaced != .unauthorized)
    #expect(Set(RelayConnectionState.allCases).count == 6)
    #expect(RelayConnectionState.reconnecting.rawValue == "reconnecting")
    #expect(String(describing: RelayConnectionState.unauthorized) == "unauthorized")
}
