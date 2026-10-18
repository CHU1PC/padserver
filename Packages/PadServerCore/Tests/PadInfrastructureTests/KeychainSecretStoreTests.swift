import Foundation
import PadDomain
@testable import PadInfrastructure
import Security
import Testing

@Suite
struct KeychainSecretStoreTests {
    @Test
    func storesReadsListsUpdatesAndRemovesProjectSecrets() async throws {
        let client = InMemoryKeychainClient()
        let store = KeychainSecretStore(client: client)
        let project = try ProjectName("example-project")
        let otherProject = try ProjectName("other-project")

        #expect(try await store.secret(named: "API_KEY", for: project) == nil)

        try await store.setSecret("first-value", named: "API_KEY", for: project)
        try await store.setSecret("second-value", named: "DATABASE_URL", for: project)
        try await store.setSecret("other-project-value", named: "API_KEY", for: otherProject)

        #expect(try await store.secret(named: "API_KEY", for: project) == "first-value")
        #expect(try await store.secretNames(for: project) == ["API_KEY", "DATABASE_URL"])
        #expect(try await store.secretNames(for: otherProject) == ["API_KEY"])

        try await store.setSecret("updated-value", named: "API_KEY", for: project)
        #expect(try await store.secret(named: "API_KEY", for: project) == "updated-value")

        try await store.removeSecret(named: "API_KEY", for: project)
        #expect(try await store.secret(named: "API_KEY", for: project) == nil)
        #expect(try await store.secret(named: "API_KEY", for: otherProject) == "other-project-value")
        #expect(try await store.secretNames(for: project) == ["DATABASE_URL"])
    }

    @Test
    func keepsAdminTokenAndProjectSecretsInSeparateAccounts() async throws {
        let client = InMemoryKeychainClient()
        let store = KeychainSecretStore(client: client)
        let project = try ProjectName("admin-token")

        try await store.setAdminToken(AdminToken("admin-value"))
        try await store.setSecret("project-value", named: "secret", for: project)

        #expect(try await store.adminToken()?.value == "admin-value")
        #expect(try await store.secret(named: "secret", for: project) == "project-value")

        try await store.removeSecret(named: "secret", for: project)
        #expect(try await store.adminToken()?.value == "admin-value")
    }

    @Test
    func keepsRelayTokenSeparateFromAdminTokenAndReplacesIt() async throws {
        let store = KeychainSecretStore(client: InMemoryKeychainClient())

        #expect(try await store.relayToken() == nil)

        try await store.setAdminToken(AdminToken("admin-value"))
        try await store.setRelayToken(RelayToken("relay-value"))
        try await store.setRelayToken(RelayToken("updated-relay-value"))

        #expect(try await store.relayToken()?.value == "updated-relay-value")
        #expect(try await store.adminToken()?.value == "admin-value")
    }

    @Test
    func propagatesKeychainFailures() async throws {
        let client = InMemoryKeychainClient(failure: KeychainClientError.operationFailed(-25293))
        let store = KeychainSecretStore(client: client)
        let project = try ProjectName("example-project")

        await #expect(throws: KeychainClientError.operationFailed(-25293)) {
            try await store.secret(named: "API_KEY", for: project)
        }
    }

    @Test
    func newItemsAreCreatedAfterFirstUnlockThisDeviceOnly() {
        let attributes = KeychainItemAttributes.add(Data("value".utf8), service: "padserver", account: "admin-token")

        #expect(attributes[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecValueData] as? Data == Data("value".utf8))
        #expect(attributes[kSecAttrService] as? String == "padserver")
        #expect(attributes[kSecAttrAccount] as? String == "admin-token")
    }

    @Test
    func updatesMigrateExistingItemsToAfterFirstUnlockThisDeviceOnly() {
        let attributes = KeychainItemAttributes.update(Data("value".utf8))

        #expect(attributes[kSecAttrAccessible] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect(attributes[kSecValueData] as? Data == Data("value".utf8))
    }
}

private actor InMemoryKeychainClient: KeychainClient {
    private let failure: KeychainClientError?
    private var values: [KeychainAccount: Data] = [:]

    init(failure: KeychainClientError? = nil) {
        self.failure = failure
    }

    func read(service: String, account: String) throws -> Data? {
        if let failure {
            throw failure
        }
        return values[KeychainAccount(service: service, account: account)]
    }

    func write(_ data: Data, service: String, account: String) throws {
        if let failure {
            throw failure
        }
        values[KeychainAccount(service: service, account: account)] = data
    }

    func delete(service: String, account: String) throws {
        if let failure {
            throw failure
        }
        values[KeychainAccount(service: service, account: account)] = nil
    }

    func accounts(service: String, accountPrefix: String) throws -> [String] {
        if let failure {
            throw failure
        }
        return values.keys
            .filter { $0.service == service && $0.account.hasPrefix(accountPrefix) }
            .map(\.account)
    }
}

private struct KeychainAccount: Hashable, Sendable {
    let service: String
    let account: String
}
