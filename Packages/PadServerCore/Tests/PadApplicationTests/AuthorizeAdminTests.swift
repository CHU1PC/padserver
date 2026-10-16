import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func authorizeAdminRequiresTailnetAddressEvenWithCorrectToken() async throws {
    let store = InMemorySecretStore()
    let token = AdminToken("test-admin-token")
    try await store.setAdminToken(token)
    let authorize = AuthorizeAdmin(secretStore: store)

    #expect(try await authorize(token: token, address: ClientAddress("100.64.0.1")))
    #expect(try await authorize(token: token, address: ClientAddress("fd7a:115c:a1e0::1")))
    #expect(try await !authorize(token: token, address: ClientAddress("192.0.2.1")))
    #expect(try await !authorize(token: token, address: ClientAddress("127.0.0.1")))
}

@Test(arguments: [
    "xest-admin-token", "test-xdmin-token", "test-admin-tokex",
    "test-admin-token-extra", "test-admin-toke", "", "test-admin-token\0",
])
func authorizeAdminRejectsMismatchedTokens(supplied: String) async throws {
    let store = InMemorySecretStore()
    try await store.setAdminToken(AdminToken("test-admin-token"))
    let authorize = AuthorizeAdmin(secretStore: store)

    #expect(try await !authorize(token: AdminToken(supplied), address: ClientAddress("100.64.0.1")))
}

@Test func authorizeAdminRejectsUnconfiguredToken() async throws {
    let authorize = AuthorizeAdmin(secretStore: InMemorySecretStore())

    #expect(try await !authorize(token: AdminToken("test-admin-token"), address: ClientAddress("100.64.0.1")))
}
