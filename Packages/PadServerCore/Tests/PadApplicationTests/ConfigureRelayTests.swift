import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

private struct StubFailure: Error {}

private struct FailingRelayURLStore: RelayURLStore {
    func relayURL() throws -> URL? { nil }
    func setRelayURL(_ url: URL) throws { throw StubFailure() }
}

/// token の保存だけを失敗させ、他は InMemorySecretStore に任せます。
private actor FailingTokenSecretStore: SecretStore {
    private let base = InMemorySecretStore()

    func secret(named name: String, for project: ProjectName) async throws -> String? {
        try await base.secret(named: name, for: project)
    }

    func setSecret(_ value: String, named name: String, for project: ProjectName) async throws {
        try await base.setSecret(value, named: name, for: project)
    }

    func secretNames(for project: ProjectName) async throws -> [String] {
        try await base.secretNames(for: project)
    }

    func removeSecret(named name: String, for project: ProjectName) async throws {
        try await base.removeSecret(named: name, for: project)
    }

    func adminToken() async throws -> AdminToken? { try await base.adminToken() }
    func setAdminToken(_ token: AdminToken) async throws { try await base.setAdminToken(token) }
    func relayToken() async throws -> RelayToken? { try await base.relayToken() }
    func setRelayToken(_ token: RelayToken) throws { throw StubFailure() }
}

@Test func configureRelayStoresUrlAndTokenSeparately() async throws {
    let secrets = InMemorySecretStore()
    let urls = InMemoryRelayURLStore()
    let configure = ConfigureRelay(secretStore: secrets, urlStore: urls)

    try await configure(url: "wss://relay.example.com/path", token: "example-token")

    #expect(await urls.relayURL()?.absoluteString == "wss://relay.example.com/path")
    #expect(try await secrets.relayToken()?.value == "example-token")
    let loaded = try await configure.load()
    #expect(loaded?.url.absoluteString == "wss://relay.example.com/path")
    #expect(loaded?.token.value == "example-token")
}

@Test func configureRelayLoadReturnsNilWhenNothingIsStored() async throws {
    let configure = ConfigureRelay(secretStore: InMemorySecretStore(), urlStore: InMemoryRelayURLStore())
    #expect(try await configure.load() == nil)
}

@Test func configureRelayLoadReturnsNilWhenOnlyOneSideIsStored() async throws {
    let secrets = InMemorySecretStore()
    let urls = InMemoryRelayURLStore()
    let configure = ConfigureRelay(secretStore: secrets, urlStore: urls)

    try await secrets.setRelayToken(RelayToken("example-token"))
    #expect(try await configure.load() == nil)

    let onlyURL = ConfigureRelay(secretStore: InMemorySecretStore(), urlStore: urls)
    await urls.setRelayURL(try #require(URL(string: "wss://relay.example.com")))
    #expect(try await onlyURL.load() == nil)
}

@Test func configureRelayOverwritesPreviousConfig() async throws {
    let configure = ConfigureRelay(secretStore: InMemorySecretStore(), urlStore: InMemoryRelayURLStore())

    try await configure(url: "wss://relay.example.com", token: "first-token")
    try await configure(url: "https://other.example.com", token: "second-token")

    let loaded = try await configure.load()
    #expect(loaded?.url.absoluteString == "https://other.example.com")
    #expect(loaded?.token.value == "second-token")
}

@Test func configureRelayRejectsInvalidInputWithoutSaving() async throws {
    let secrets = InMemorySecretStore()
    let urls = InMemoryRelayURLStore()
    let configure = ConfigureRelay(secretStore: secrets, urlStore: urls)

    await #expect(throws: RelayConfig.ValidationError.invalidURL) {
        try await configure(url: "not a url", token: "example-token")
    }
    await #expect(throws: RelayConfig.ValidationError.unsupportedScheme) {
        try await configure(url: "http://relay.example.com", token: "example-token")
    }
    await #expect(throws: RelayConfig.ValidationError.emptyToken) {
        try await configure(url: "wss://relay.example.com", token: "  ")
    }

    #expect(try await secrets.relayToken() == nil)
    #expect(await urls.relayURL() == nil)
}

@Test func configureRelayKeepsPreviousConfigWhenInputIsInvalid() async throws {
    let configure = ConfigureRelay(secretStore: InMemorySecretStore(), urlStore: InMemoryRelayURLStore())
    try await configure(url: "wss://relay.example.com", token: "first-token")

    await #expect(throws: RelayConfig.ValidationError.emptyToken) {
        try await configure(url: "wss://other.example.com", token: "")
    }

    #expect(try await configure.load()?.token.value == "first-token")
}

@Test func configureRelayRestoresPreviousTokenWhenUrlSaveFails() async throws {
    let secrets = InMemorySecretStore()
    let urls = InMemoryRelayURLStore()
    try await ConfigureRelay(secretStore: secrets, urlStore: urls)(url: "wss://relay.example.com", token: "first-token")

    let failing = ConfigureRelay(secretStore: secrets, urlStore: FailingRelayURLStore())
    await #expect(throws: StubFailure.self) {
        try await failing(url: "wss://other.example.com", token: "second-token")
    }

    #expect(try await secrets.relayToken()?.value == "first-token")
    #expect(await urls.relayURL()?.absoluteString == "wss://relay.example.com")
}

@Test func configureRelayLeavesNoConfigWhenFirstUrlSaveFails() async throws {
    let secrets = InMemorySecretStore()
    let failing = ConfigureRelay(secretStore: secrets, urlStore: FailingRelayURLStore())

    await #expect(throws: StubFailure.self) {
        try await failing(url: "wss://relay.example.com", token: "example-token")
    }

    #expect(try await failing.load() == nil)
}

@Test func configureRelayDoesNotSaveUrlWhenTokenSaveFails() async throws {
    let urls = InMemoryRelayURLStore()
    let configure = ConfigureRelay(secretStore: FailingTokenSecretStore(), urlStore: urls)

    await #expect(throws: StubFailure.self) {
        try await configure(url: "wss://relay.example.com", token: "example-token")
    }

    #expect(await urls.relayURL() == nil)
}

@Test func configureRelayErrorsAndOutputsDoNotContainToken() async throws {
    let secretToken = "very-secret-token-value"
    let configure = ConfigureRelay(secretStore: InMemorySecretStore(), urlStore: InMemoryRelayURLStore())

    do {
        try await configure(url: "ftp://relay.example.com", token: secretToken)
        Issue.record("expected a validation error")
    } catch {
        #expect(!String(describing: error).contains(secretToken))
        #expect(!String(reflecting: error).contains(secretToken))
    }

    try await configure(url: "wss://relay.example.com", token: secretToken)
    let loaded = try #require(try await configure.load())
    #expect(!String(describing: loaded).contains(secretToken))
    #expect(!String(reflecting: loaded).contains(secretToken))
    #expect(!String(describing: loaded.token).contains(secretToken))
}
