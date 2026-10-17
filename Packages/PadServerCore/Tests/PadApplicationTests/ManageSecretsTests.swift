import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func manageSecretsKeepsValuesPerProjectAndListsOnlyNames() async throws {
    let store = InMemorySecretStore()
    let manage = ManageSecrets(store: store)
    let first = try ProjectName("first")
    let second = try ProjectName("second")

    try await manage.set("first-value", named: "API_KEY", for: first)
    try await manage.set("second-value", named: "API_KEY", for: second)
    try await manage.set("other-value", named: "TOKEN", for: first)

    #expect(try await manage.names(for: first) == ["API_KEY", "TOKEN"])
    #expect(try await manage.names(for: second) == ["API_KEY"])
    #expect(try await store.secret(named: "API_KEY", for: first) == "first-value")
    #expect(try await store.secret(named: "API_KEY", for: second) == "second-value")
}

@Test func manageSecretsRemovesOnlyNamedProjectSecret() async throws {
    let store = InMemorySecretStore()
    let manage = ManageSecrets(store: store)
    let first = try ProjectName("first")
    let second = try ProjectName("second")

    try await manage.set("first-value", named: "API_KEY", for: first)
    try await manage.set("second-value", named: "API_KEY", for: second)
    try await manage.remove(named: "API_KEY", for: first)

    #expect(try await manage.names(for: first).isEmpty)
    #expect(try await manage.names(for: second) == ["API_KEY"])
    #expect(try await store.secret(named: "API_KEY", for: first) == nil)
    #expect(try await store.secret(named: "API_KEY", for: second) == "second-value")
}
