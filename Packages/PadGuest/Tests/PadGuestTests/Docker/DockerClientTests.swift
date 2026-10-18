import Foundation
@testable import PadGuest
import Testing

private let versionJSON = #"{"Version":"29.9.1","ApiVersion":"1.54","Os":"linux","Arch":"amd64"}"#

@Test(.timeLimit(.minutes(1)))
func dockerClientReadsVersionOverMutualTLS() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: credentials, routes: ["/version": TLSTestResponse(status: 200, body: versionJSON)])
    defer { server.stop() }

    let version = try await DockerClient(hostPort: server.port, credentials: credentials).version()

    #expect(version == DockerVersion(version: "29.9.1", apiVersion: "1.54"))
}

@Test(.timeLimit(.minutes(1)))
func dockerClientPingSucceedsOnOK() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: credentials, routes: ["/_ping": TLSTestResponse(status: 200, body: "OK")])
    defer { server.stop() }

    try await DockerClient(hostPort: server.port, credentials: credentials).ping()
}

@Test(.timeLimit(.minutes(1)))
func dockerClientPingRejectsErrorStatus() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: credentials, routes: ["/_ping": TLSTestResponse(status: 500, body: "boom")])
    defer { server.stop() }
    let client = try DockerClient(hostPort: server.port, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) { try await client.ping() }
}

@Test(.timeLimit(.minutes(1)))
func dockerClientPingRejectsUnexpectedBody() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: credentials, routes: ["/_ping": TLSTestResponse(status: 200, body: "NG")])
    defer { server.stop() }
    let client = try DockerClient(hostPort: server.port, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.invalidResponse) { try await client.ping() }
}

@Test(.timeLimit(.minutes(1)))
func dockerClientVersionRejectsMalformedBody() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: credentials, routes: ["/version": TLSTestResponse(status: 200, body: "not json")])
    defer { server.stop() }
    let client = try DockerClient(hostPort: server.port, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.invalidResponse) { try await client.version() }
}

@Test(.timeLimit(.minutes(1)))
func dockerClientVersionRejectsErrorStatus() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: credentials, routes: ["/version": TLSTestResponse(status: 503, body: "")])
    defer { server.stop() }
    let client = try DockerClient(hostPort: server.port, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.unexpectedStatus(503)) { try await client.version() }
}

@Test(.timeLimit(.minutes(1)))
func dockerClientFailsWhenNothingListens() async throws {
    let credentials = try await makeTestCredentials()
    let closedPort = try PortForwarder.freeLoopbackPort()
    let client = try DockerClient(hostPort: closedPort, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.connectionFailed) { try await client.ping() }
}

@Test(.timeLimit(.minutes(1)))
func dockerClientRejectsServerNotSignedByCA() async throws {
    let credentials = try await makeTestCredentials()
    let other = try await makeTestCredentials()
    let server = try await TLSTestServer.start(
        credentials: other, routes: ["/_ping": TLSTestResponse(status: 200, body: "OK")])
    defer { server.stop() }
    let client = try DockerClient(hostPort: server.port, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.connectionFailed) { try await client.ping() }
}

@Test(.timeLimit(.minutes(1)))
func dockerClientIsRejectedWhenClientCertificateIsNotSignedByServerCA() async throws {
    let server = try await makeTestCredentials()
    let other = try await makeTestCredentials()
    let listener = try await TLSTestServer.start(
        credentials: server, routes: ["/_ping": TLSTestResponse(status: 200, body: "OK")])
    defer { listener.stop() }
    let foreign = GuestCredentials(
        caCertificatePEM: server.caCertificatePEM,
        serverCertificatePEM: server.serverCertificatePEM,
        serverKeyPEM: server.serverKeyPEM,
        clientCertificatePEM: other.clientCertificatePEM,
        clientKeyPEM: other.clientKeyPEM)
    let client = try DockerClient(hostPort: listener.port, credentials: foreign)

    await #expect(throws: DockerClient.ClientError.connectionFailed) { try await client.ping() }
}

@Test func dockerClientRejectsBrokenCredentials() async throws {
    let valid = try await makeTestCredentials()
    let broken = GuestCredentials(
        caCertificatePEM: "not a pem",
        serverCertificatePEM: valid.serverCertificatePEM,
        serverKeyPEM: valid.serverKeyPEM,
        clientCertificatePEM: valid.clientCertificatePEM,
        clientKeyPEM: valid.clientKeyPEM)

    #expect(throws: DockerClient.ClientError.invalidCredentials) {
        try DockerClient(hostPort: 1, credentials: broken)
    }
}
