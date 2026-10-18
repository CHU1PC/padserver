import Foundation
import PadApplication
import PadDomain
import Synchronization
import Testing

@testable import PadInfrastructure

private final class FakeSocket: RelaySocket, Sendable {
    private let stream: AsyncThrowingStream<RelaySocketMessage, any Error>
    private let continuation: AsyncThrowingStream<RelaySocketMessage, any Error>.Continuation
    private let closed = Mutex<[Int]>([])

    init() {
        (stream, continuation) = AsyncThrowingStream<RelaySocketMessage, any Error>.makeStream()
    }

    var closedCodes: [Int] {
        closed.withLock { $0 }
    }

    func receive() async throws -> RelaySocketMessage {
        var iterator = stream.makeAsyncIterator()
        guard let message = try await iterator.next() else { throw RelaySocketError.closed(code: nil) }
        return message
    }

    func close(code: Int) {
        closed.withLock { $0.append(code) }
        continuation.finish()
    }

    func push(_ message: RelaySocketMessage) {
        continuation.yield(message)
    }

    func fail(_ error: RelaySocketError) {
        continuation.finish(throwing: error)
    }
}

private actor FakeConnector: RelaySocketConnecting {
    private let outcome: Result<FakeSocket, RelaySocketError>
    private(set) var requests: [URLRequest] = []

    init(_ outcome: Result<FakeSocket, RelaySocketError>) {
        self.outcome = outcome
    }

    func open(_ request: URLRequest) async throws -> any RelaySocket {
        requests.append(request)
        await Task.yield()
        return try outcome.get()
    }
}

private func makeConfig(url: String = "wss://relay.example.com") throws -> RelayConfig {
    try RelayConfig(url: url, token: "example-token")
}

private func nextStates(_ client: RelayClient, count: Int) async -> [RelayConnectionState] {
    var iterator = client.stateChanges.makeAsyncIterator()
    var states: [RelayConnectionState] = []
    while states.count < count, let state = await iterator.next() {
        states.append(state)
    }
    return states
}

private func start(_ client: RelayClient, expecting count: Int) async throws -> [RelayConnectionState] {
    let config = try makeConfig()
    async let states = nextStates(client, count: count)
    await client.start(config)
    return await states
}

@Test func relayClientStartsDisconnected() async {
    let client = RelayClient(connector: FakeConnector(.success(FakeSocket())))
    #expect(await client.state() == .disconnected)
}

@Test func relayClientSendsTunnelPathBearerTokenAndProtocolVersion() async throws {
    let connector = FakeConnector(.success(FakeSocket()))
    let client = RelayClient(connector: connector)

    _ = try await start(client, expecting: 2)

    let request = try #require(await connector.requests.first)
    #expect(request.url?.absoluteString == "wss://relay.example.com/_padserver/tunnel")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer example-token")
    #expect(request.value(forHTTPHeaderField: "Sec-WebSocket-Protocol") == "padserver-relay.v1")
}

@Test func relayClientRewritesHTTPSURLToWSSAndReplacesPath() async throws {
    let connector = FakeConnector(.success(FakeSocket()))
    let client = RelayClient(connector: connector)

    await client.start(try makeConfig(url: "https://relay.example.com/other?x=1"))

    let request = try #require(await connector.requests.first)
    #expect(request.url?.absoluteString == "wss://relay.example.com/_padserver/tunnel")
}

@Test func relayClientMovesFromConnectingToConnected() async throws {
    let client = RelayClient(connector: FakeConnector(.success(FakeSocket())))

    let states = try await start(client, expecting: 2)

    #expect(states == [.connecting, .connected])
    #expect(await client.state() == .connected)
}

@Test func relayClientBecomesUnauthorizedOn401WithoutRetrying() async throws {
    let connector = FakeConnector(.failure(.upgradeRejected(status: 401)))
    let client = RelayClient(connector: connector)

    let states = try await start(client, expecting: 2)

    #expect(states == [.connecting, .unauthorized])
    #expect(await connector.requests.count == 1)
}

@Test func relayClientBecomesReconnectingOnServerErrorDuringUpgrade() async throws {
    let client = RelayClient(connector: FakeConnector(.failure(.upgradeRejected(status: 503))))

    let states = try await start(client, expecting: 2)

    #expect(states == [.connecting, .reconnecting])
}

@Test func relayClientBecomesReconnectingOnTransportFailure() async throws {
    let client = RelayClient(connector: FakeConnector(.failure(.closed(code: nil))))

    let states = try await start(client, expecting: 2)

    #expect(states == [.connecting, .reconnecting])
}

@Test func relayClientBecomesReplacedOnCloseCode4000WithoutRetrying() async throws {
    let socket = FakeSocket()
    let connector = FakeConnector(.success(socket))
    let client = RelayClient(connector: connector)

    async let states = nextStates(client, count: 3)
    await client.start(try makeConfig())
    socket.fail(.closed(code: 4000))

    #expect(await states == [.connecting, .connected, .replaced])
    #expect(await connector.requests.count == 1)
}

@Test(arguments: [1006, 1001, 4001])
func relayClientBecomesReconnectingOnOtherCloseCodes(code: Int) async throws {
    let socket = FakeSocket()
    let client = RelayClient(connector: FakeConnector(.success(socket)))

    async let states = nextStates(client, count: 3)
    await client.start(try makeConfig())
    socket.fail(.closed(code: code))

    #expect(await states == [.connecting, .connected, .reconnecting])
}

@Test func relayClientPassesDecodedFramesAndIgnoresTextMessages() async throws {
    let socket = FakeSocket()
    let client = RelayClient(connector: FakeConnector(.success(socket)))
    var frames = client.frames.makeAsyncIterator()

    await client.start(try makeConfig())
    socket.push(.text("pong"))
    socket.push(.data(try RelayFrame.reqEnd(id: 7).encode()))
    socket.push(.data(try RelayFrame.cancel(id: 9).encode()))

    #expect(await frames.next() == .reqEnd(id: 7))
    #expect(await frames.next() == .cancel(id: 9))
}

@Test func relayClientSkipsRequestLevelInvalidFramesAndKeepsConnection() async throws {
    let socket = FakeSocket()
    let client = RelayClient(connector: FakeConnector(.success(socket)))
    var frames = client.frames.makeAsyncIterator()

    await client.start(try makeConfig())
    socket.push(.data(Data([1, 0, 0, 0, 1]) + Data("not json".utf8)))
    socket.push(.data(try RelayFrame.reqEnd(id: 2).encode()))

    #expect(await frames.next() == .reqEnd(id: 2))
    #expect(await client.state() == .connected)
}

@Test func relayClientClosesWith4001AndReconnectsOnProtocolError() async throws {
    let socket = FakeSocket()
    let client = RelayClient(connector: FakeConnector(.success(socket)))

    async let states = nextStates(client, count: 3)
    await client.start(try makeConfig())
    socket.push(.data(Data([1, 2])))

    #expect(await states == [.connecting, .connected, .reconnecting])
    #expect(socket.closedCodes == [4001])
}

@Test func relayClientStopClosesSocketAndDisconnects() async throws {
    let socket = FakeSocket()
    let client = RelayClient(connector: FakeConnector(.success(socket)))

    await client.start(try makeConfig())
    await client.stop()

    #expect(await client.state() == .disconnected)
    #expect(socket.closedCodes == [1000])
}
