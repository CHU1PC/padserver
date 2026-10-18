import PadApplication
import PadDomain
import PadTestSupport
import Testing

private func makeConfig() throws -> RelayConfig {
    try RelayConfig(url: "wss://relay.example.com", token: "example-token")
}

@Test func inMemoryRelayConnectionStartsDisconnected() async {
    let connection: any RelayConnection = InMemoryRelayConnection()
    #expect(await connection.state() == .disconnected)
}

@Test func inMemoryRelayConnectionMovesToConfiguredStateOnStart() async throws {
    let config = try makeConfig()
    let connection = InMemoryRelayConnection(stateOnStart: .unauthorized)
    let port: any RelayConnection = connection

    await port.start(config)

    #expect(await port.state() == .unauthorized)
    #expect(await connection.startedConfig?.url == config.url)
}

@Test func inMemoryRelayConnectionDefaultsToConnectedOnStart() async throws {
    let connection: any RelayConnection = InMemoryRelayConnection()
    await connection.start(try makeConfig())
    #expect(await connection.state() == .connected)
}

@Test func inMemoryRelayConnectionReturnsToDisconnectedOnStop() async throws {
    let connection: any RelayConnection = InMemoryRelayConnection()
    await connection.start(try makeConfig())
    await connection.stop()
    #expect(await connection.state() == .disconnected)
}
