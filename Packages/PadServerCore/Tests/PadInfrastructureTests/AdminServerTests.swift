import Foundation
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
    static let tailnetAddress = "100.64.0.1"
    static let connectionTimeout = Duration.seconds(1)
    // clientAddress は IP のみを使うため、試験用 socket port は表示的な値にする。
    static let exampleSocketPort = 443
    static let exampleClientAddress = "198.51.100.7"
    static let spoofedForwardedAddress = "203.0.113.9"
}

@Test func adminServerKeepsAdminRoutesSeparateFromDeliveryRoutes() async throws {
    let adminApplication = try AdminServer.makeApplication(
        adminPort: AdminServerTestConstants.adminPort,
        deliveryPort: AdminServerTestConstants.deliveryPort,
        tailnetAddress: AdminServerTestConstants.tailnetAddress
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
        deliveryPort: AdminServerTestConstants.deliveryPort,
        tailnetAddress: AdminServerTestConstants.tailnetAddress
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
        deliveryPort: AdminServerTestConstants.deliveryPort,
        tailnetAddress: AdminServerTestConstants.tailnetAddress
    )

    #expect(
        application.configuration.address
            == .hostname(AdminServerTestConstants.tailnetAddress, port: AdminServerTestConstants.adminPort)
    )
}

@Test func adminServerRejectsPortSharedWithDeliveryServer() {
    #expect(throws: AdminServerError.portsMustBeDistinct) {
        try AdminServer.makeApplication(
            adminPort: AdminServerTestConstants.adminPort,
            deliveryPort: AdminServerTestConstants.adminPort,
            tailnetAddress: AdminServerTestConstants.tailnetAddress
        )
    }
}

@Test(arguments: ["0.0.0.0", "127.0.0.1", "192.168.1.10"])
func adminServerRejectsAddressesOutsideTailnet(address: String) {
    #expect(throws: AdminServerError.invalidTailnetAddress) {
        try AdminServer.makeApplication(
            adminPort: AdminServerTestConstants.adminPort,
            deliveryPort: AdminServerTestConstants.deliveryPort,
            tailnetAddress: address
        )
    }
}

@Test(
    .enabled(if: ProcessInfo.processInfo.environment["PADSERVER_TEST_TAILNET_IP"] != nil),
    .timeLimit(.minutes(1))
)
func adminServerAcceptsOnlyItsTailnetInterface() async throws {
    let tailnetAddress = try #require(ProcessInfo.processInfo.environment["PADSERVER_TEST_TAILNET_IP"])
    let configured = try AdminServer.makeApplication(
        adminPort: 0,
        deliveryPort: AdminServerTestConstants.deliveryPort,
        tailnetAddress: tailnetAddress
    ) { router in
        router.get("/admin-probe") { _, _ in Response(status: .ok) }
    }
    let started = AsyncStream<Int>.makeStream()
    let application = Application(
        responder: configured.responder,
        configuration: configured.configuration,
        onServerRunning: { channel in
            if let port = channel.localAddress?.port {
                started.continuation.yield(port)
            }
        }
    )
    let server = Task { try await application.run() }
    defer { server.cancel() }
    var iterator = started.stream.makeAsyncIterator()
    let port = try #require(await iterator.next())

    try await TestClient.withClient(host: tailnetAddress, port: port) { tailnetClient in
        let response = try await tailnetClient.get("/admin-probe")
        #expect(response.status == .ok)
    }
    #expect(await canConnectFromLocalhost(port: port) == false)
}

private func canConnectFromLocalhost(port: Int) async -> Bool {
    do {
        return try await TestClient.withClient(
            host: "127.0.0.1",
            port: port,
            configuration: .init(timeout: AdminServerTestConstants.connectionTimeout)
        ) { outsideClient in
            _ = try await outsideClient.get("/admin-probe")
            return true
        }
    } catch {
        return false
    }
}
