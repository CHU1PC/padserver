import Hummingbird
import HummingbirdTesting
import HTTPTypes
import NIOCore
import PadDomain
@testable import PadInfrastructure
import Testing

private enum AdminServerTestConstants {
    // Router 試験は bind しないため、設定比較用の port を使う。
    static let adminPort = 8081
    static let deliveryPort = 8080
    // clientAddress は IP のみを使うため、試験用 socket port は表示的な値にする。
    static let exampleSocketPort = 443
    static let exampleClientAddress = "198.51.100.7"
    static let spoofedForwardedAddress = "203.0.113.9"
}

@Test func adminServerKeepsAdminRoutesSeparateFromDeliveryRoutes() async throws {
    let adminApplication = try AdminServer.makeApplication(
        adminPort: AdminServerTestConstants.adminPort,
        deliveryPort: AdminServerTestConstants.deliveryPort
    ) { router in
        router.get("/admin-probe") { _, _ in
            Response(status: .ok)
        }
    }
    let deliveryRouter = Router(context: AdminRequestContext.self)
    deliveryRouter.get("/delivery-probe") { _, _ in
        Response(status: .ok)
    }
    let deliveryApplication = Application(responder: deliveryRouter.buildResponder())

    try await adminApplication.test(.router) { client in
        let adminResponse = try await client.execute(uri: "/admin-probe", method: .get)
        let deliveryResponse = try await client.execute(uri: "/delivery-probe", method: .get)

        #expect(adminResponse.status == .ok)
        #expect(deliveryResponse.status == .notFound)
    }

    try await deliveryApplication.test(.router) { client in
        let deliveryResponse = try await client.execute(uri: "/delivery-probe", method: .get)
        let adminResponse = try await client.execute(uri: "/admin-probe", method: .get)

        #expect(deliveryResponse.status == .ok)
        #expect(adminResponse.status == .notFound)
    }
}

@Test func adminRequestContextUsesTransportAddressInsteadOfForwardedHeader() async throws {
    let forwardedHeaderName = try #require(HTTPField.Name("Forwarded"))
    let xForwardedForHeaderName = try #require(HTTPField.Name("X-Forwarded-For"))
    let application = try AdminServer.makeApplication(
        adminPort: AdminServerTestConstants.adminPort,
        deliveryPort: AdminServerTestConstants.deliveryPort
    ) { router in
        router.get("/client-address") { _, context in
            Response(status: context.clientAddress == nil ? .noContent : .ok)
        }
    }

    try await application.test(.router) { client in
        var headers = HTTPFields()
        headers[forwardedHeaderName] = AdminServerTestConstants.spoofedForwardedAddress
        headers[xForwardedForHeaderName] = AdminServerTestConstants.spoofedForwardedAddress
        let response = try await client.execute(
            uri: "/client-address",
            method: .get,
            headers: headers
        )

        #expect(response.status == .noContent)
    }

    let socketAddress = try SocketAddress(
        ipAddress: AdminServerTestConstants.exampleClientAddress,
        port: AdminServerTestConstants.exampleSocketPort
    )
    #expect(
        AdminRequestContext.clientAddress(from: socketAddress)
            == ClientAddress(AdminServerTestConstants.exampleClientAddress)
    )
}

@Test func adminServerBindsToItsConfiguredPort() throws {
    let application = try AdminServer.makeApplication(
        adminPort: AdminServerTestConstants.adminPort,
        deliveryPort: AdminServerTestConstants.deliveryPort
    )

    #expect(
        application.configuration.address == .hostname("0.0.0.0", port: AdminServerTestConstants.adminPort)
    )
}

@Test func adminServerRejectsPortSharedWithDeliveryServer() {
    #expect(throws: AdminServerError.portsMustBeDistinct) {
        try AdminServer.makeApplication(
            adminPort: AdminServerTestConstants.adminPort,
            deliveryPort: AdminServerTestConstants.adminPort
        )
    }
}
