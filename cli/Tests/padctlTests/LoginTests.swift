import Foundation
import Security
import Testing
@testable import padctl

@Test func loginCommandIsRegisteredAndParsesServerURL() throws {
    let command = try Padctl.parseAsRoot(["login", "https://pad.example.com"])
    let login = try #require(command as? Login)
    #expect(login.serverURL == "https://pad.example.com")
}

@Test func loginPersistsServerAndTokenInSeparateStores() throws {
    let serverURL = try #require(URL(string: "https://pad.example.com"))
    let configStore = InMemoryConfigStore()
    let tokenStore = InMemoryTokenStore()
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)

    try service.login(serverURL: serverURL, token: "dummy-token")

    #expect(configStore.config?.serverURL == serverURL)
    #expect(tokenStore.token == "dummy-token")
}

@Test func loginRejectsEmptyTokenWithoutWritingStores() throws {
    let configStore = InMemoryConfigStore()
    let tokenStore = InMemoryTokenStore()
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)
    let serverURL = try #require(URL(string: "https://pad.example.com"))

    #expect(throws: LoginError.emptyToken) {
        try service.login(serverURL: serverURL, token: "")
    }

    #expect(configStore.config == nil)
    #expect(tokenStore.token == nil)
}

@Test func defaultConfigPathUsesXDGConfigDirectory() {
    #expect(ConfigFileStore.defaultFileURL().path().hasSuffix("/.config/padctl/config.json"))
}

@Test func configFileStoreWritesOnlyServerURLAsJSON() throws {
    let directory = FileManager.default.temporaryDirectory
        .appending(path: "padctl-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the temporary config directory.")
        }
    }
    let fileURL = directory.appending(path: "config.json")
    let store = ConfigFileStore(fileURL: fileURL)
    let config = try PadctlConfig(serverURL: #require(URL(string: "https://pad.example.com")))

    try store.save(config)

    let data = try Data(contentsOf: fileURL)
    let jsonKeys = try JSONDecoder().decode(JSONConfigKeys.self, from: data)
    #expect(jsonKeys.keys == ["serverURL"])
    let decodedConfig = try JSONDecoder().decode(PadctlConfig.self, from: data)
    #expect(decodedConfig.serverURL.absoluteString == "https://pad.example.com")
    let contents = try #require(String(bytes: data, encoding: .utf8))
    #expect(contents.localizedCaseInsensitiveContains("token") == false)
    #expect(try store.load() == config)
}

@Test func loginRestoresOldConfigAndTokenWhenConfigSaveFails() throws {
    let serverURL = try #require(URL(string: "https://pad.example.com"))
    let oldConfig = try PadctlConfig(serverURL: #require(URL(string: "https://old.example.com")))
    let configStore = InMemoryConfigStore(config: oldConfig, failNextSaveAfterWriting: true)
    let tokenStore = InMemoryTokenStore(token: "old-token")
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)

    #expect(throws: LoginError.persistenceFailed) {
        try service.login(serverURL: serverURL, token: "new-token")
    }

    #expect(configStore.config == oldConfig)
    #expect(tokenStore.token == "old-token")
}

@Test func loginPreservesDeviceIDEditedInConfigFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "padctl-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the temporary config directory.")
        }
    }
    let fileURL = directory.appending(path: "config.json")
    let editedConfig = #"{"serverURL":"https://old.example.com","deviceID":"example-device"}"#
    try Data(editedConfig.utf8).write(to: fileURL)
    let configStore = ConfigFileStore(fileURL: fileURL)
    let tokenStore = InMemoryTokenStore()
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)
    let newURL = try #require(URL(string: "https://new.example.com"))

    try service.login(serverURL: newURL, token: "dummy-token")

    #expect(try configStore.load()?.serverURL == newURL)
    #expect(try configStore.load()?.deviceID == "example-device")
    #expect(tokenStore.token == "dummy-token")
}

@Test func loginRestoresTokenWhenTokenSaveFailsAfterWriting() throws {
    let serverURL = try #require(URL(string: "https://pad.example.com"))
    let oldConfig = try PadctlConfig(serverURL: #require(URL(string: "https://old.example.com")))
    let configStore = InMemoryConfigStore(config: oldConfig)
    let tokenStore = InMemoryTokenStore(token: "old-token", failNextSaveAfterWriting: true)
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)

    #expect(throws: LoginError.persistenceFailed) {
        try service.login(serverURL: serverURL, token: "new-token")
    }

    #expect(configStore.config == oldConfig)
    #expect(tokenStore.token == "old-token")
}

@Test func configRejectsURLUserInfoWhenCreatedAndDecoded() throws {
    let url = try #require(URL(string: "https://user:password@pad.example.com"))
    #expect(throws: ConfigError.invalidServerURL) {
        try PadctlConfig(serverURL: url)
    }

    let data = Data(#"{"serverURL":"https://user:password@pad.example.com"}"#.utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(PadctlConfig.self, from: data)
    }
}

@Test func configRejectsNonHTTPOrHostlessURLs() throws {
    let invalidURLs = [
        try #require(URL(string: "ftp://pad.example.com")),
        try #require(URL(string: "file:///tmp/padctl")),
        try #require(URL(string: "https:///path")),
    ]

    for url in invalidURLs {
        #expect(throws: ConfigError.invalidServerURL) {
            try PadctlConfig(serverURL: url)
        }
    }
}

@Test func tokenInputRejectsBytesOverMaximum() {
    let tooLongToken = Data(repeating: 120, count: TokenInput.maximumByteCount + 1)

    #expect(throws: TokenInputError.tooLong) {
        try TokenInput.decode(tooLongToken)
    }
}

@Test func loginDoesNotStoreTokenOverMaximum() throws {
    let serverURL = try #require(URL(string: "https://pad.example.com"))
    let configStore = InMemoryConfigStore()
    let tokenStore = InMemoryTokenStore()
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)
    let tooLongToken = String(repeating: "x", count: TokenInput.maximumByteCount + 1)

    #expect(throws: TokenInputError.tooLong) {
        try service.login(serverURL: serverURL, token: tooLongToken)
    }

    #expect(configStore.config == nil)
    #expect(tokenStore.token == nil)
}

@Test func keychainIdentityUsesAdminTokenGenericPasswordAttributes() {
    let identity = KeychainTokenIdentity.default

    #expect(identity.service == "padctl")
    #expect(identity.account == "admin-token")
    #expect(identity.query[kSecClass as String] as? String == kSecClassGenericPassword as String)
    #expect(identity.query[kSecAttrService as String] as? String == "padctl")
    #expect(identity.query[kSecAttrAccount as String] as? String == "admin-token")
}

private final class InMemoryConfigStore: ConfigStore {
    private(set) var config: PadctlConfig?
    private var failNextSaveAfterWriting: Bool

    init(config: PadctlConfig? = nil, failNextSaveAfterWriting: Bool = false) {
        self.config = config
        self.failNextSaveAfterWriting = failNextSaveAfterWriting
    }

    func load() throws -> PadctlConfig? {
        config
    }

    func save(_ config: PadctlConfig?) throws {
        self.config = config
        if failNextSaveAfterWriting {
            failNextSaveAfterWriting = false
            throw LoginError.persistenceFailed
        }
    }
}

private struct JSONConfigKeys: Decodable {
    let keys: Set<String>

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicCodingKey.self)
        keys = Set(container.allKeys.map(\.stringValue))
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private final class InMemoryTokenStore: TokenStore {
    private(set) var token: String?
    private var failNextSaveAfterWriting: Bool

    init(token: String? = nil, failNextSaveAfterWriting: Bool = false) {
        self.token = token
        self.failNextSaveAfterWriting = failNextSaveAfterWriting
    }

    func load() throws -> String? {
        token
    }

    func save(_ token: String?) throws {
        self.token = token
        if failNextSaveAfterWriting {
            failNextSaveAfterWriting = false
            throw LoginError.persistenceFailed
        }
    }
}
