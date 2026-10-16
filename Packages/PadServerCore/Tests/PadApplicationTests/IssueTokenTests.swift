@testable import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func issueTokenSavesAndReturnsGeneratedToken() async throws {
    let store = InMemorySecretStore()
    let issue = IssueToken(secretStore: store, makeToken: { AdminToken("example-token-one") })

    let token = try await issue()

    #expect(token.value == "example-token-one")
    #expect(try await store.adminToken()?.value == token.value)
}

@Test func issueTokenReplacesPreviouslyStoredToken() async throws {
    let store = InMemorySecretStore()
    let first = IssueToken(secretStore: store, makeToken: { AdminToken("example-token-one") })
    let second = IssueToken(secretStore: store, makeToken: { AdminToken("example-token-two") })
    let oldToken = try await first()

    let newToken = try await second()

    #expect(oldToken.value != newToken.value)
    #expect(try await store.adminToken()?.value == newToken.value)
}
