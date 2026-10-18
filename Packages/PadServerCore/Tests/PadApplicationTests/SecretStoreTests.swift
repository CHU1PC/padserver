import PadApplication
import PadDomain
import Testing

@Test func secretStorePersistsProjectSecretsWithoutListingValues() async throws {
    let store = InMemorySecretStore()
    let project = try ProjectName("example")
    let secretName = "API_KEY"
    let firstValue = "example.com"
    let updatedValue = "updated.example.com"

    #expect(try await store.secret(named: secretName, for: project) == nil)

    try await store.setSecret(firstValue, named: secretName, for: project)
    #expect(try await store.secret(named: secretName, for: project) == firstValue)

    try await store.setSecret(updatedValue, named: secretName, for: project)
    #expect(try await store.secret(named: secretName, for: project) == updatedValue)
    #expect(try await store.secretNames(for: project) == [secretName])

    try await store.removeSecret(named: secretName, for: project)
    #expect(try await store.secret(named: secretName, for: project) == nil)
    #expect(try await store.secretNames(for: project).isEmpty)
}

@Test func secretStorePersistsAndReplacesAdminToken() async throws {
    let store = InMemorySecretStore()
    let initialToken = AdminToken("example.com")
    let replacementToken = AdminToken("updated.example.com")

    #expect(try await store.adminToken() == nil)

    try await store.setAdminToken(initialToken)
    #expect(try await store.adminToken()?.value == initialToken.value)

    try await store.setAdminToken(replacementToken)
    #expect(try await store.adminToken()?.value == replacementToken.value)
}

private actor InMemorySecretStore: SecretStore {
    private struct SecretKey: Hashable {
        let project: ProjectName
        let name: String
    }

    private var secrets: [SecretKey: String] = [:]
    private var currentAdminToken: AdminToken?
    private var currentRelayToken: RelayToken?

    func secret(named name: String, for project: ProjectName) throws -> String? {
        secrets[SecretKey(project: project, name: name)]
    }

    func setSecret(_ value: String, named name: String, for project: ProjectName) throws {
        secrets[SecretKey(project: project, name: name)] = value
    }

    func secretNames(for project: ProjectName) throws -> [String] {
        secrets.keys
            .filter { $0.project == project }
            .map(\.name)
            .sorted()
    }

    func removeSecret(named name: String, for project: ProjectName) throws {
        secrets.removeValue(forKey: SecretKey(project: project, name: name))
    }

    func adminToken() throws -> AdminToken? {
        currentAdminToken
    }

    func setAdminToken(_ token: AdminToken) throws {
        currentAdminToken = token
    }

    func relayToken() throws -> RelayToken? {
        currentRelayToken
    }

    func setRelayToken(_ token: RelayToken) throws {
        currentRelayToken = token
    }
}
