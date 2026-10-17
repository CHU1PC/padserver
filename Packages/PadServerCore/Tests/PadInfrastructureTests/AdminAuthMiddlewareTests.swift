import Hummingbird
import HummingbirdTesting
import HTTPTypes
import PadApplication
import PadDomain
import PadInfrastructure
import PadTestSupport
import Testing

@Test func adminAuthMiddlewareReturnsUnauthorizedWithoutValidBearerToken() async throws {
    let store = InMemorySecretStore()
    try await store.setAdminToken(AdminToken("valid-token"))
    let application = try AdminServer.makeApplication(
        adminPort: 8081,
        deliveryPort: 8080,
        tailnetAddress: "100.64.0.1",
        authorizeAdmin: AuthorizeAdmin(secretStore: store)
    ) { router in
        router.get("/admin-probe") { _, _ in Response(status: .ok) }
    }

    try await application.test(.router) { client in
        let missing = try await client.execute(uri: "/admin-probe", method: .get)
        #expect(missing.status == .unauthorized)

        for authorization in ["valid-token", "Bearer ", "Bearer wrong-token"] {
            var headers = HTTPFields()
            headers[.authorization] = authorization
            let response = try await client.execute(uri: "/admin-probe", method: .get, headers: headers)
            #expect(response.status == .unauthorized)
        }

        var validHeaders = HTTPFields()
        validHeaders[.authorization] = "Bearer valid-token"
        let outside = try await client.execute(uri: "/admin-probe", method: .get, headers: validHeaders)
        #expect(outside.status == .forbidden)

        validHeaders[.authorization] = "bearer valid-token"
        let lowercaseScheme = try await client.execute(uri: "/admin-probe", method: .get, headers: validHeaders)
        #expect(lowercaseScheme.status == .forbidden)
    }
}
