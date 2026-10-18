import Foundation
import PadApplication
import PadDomain

public actor RelayClient: RelayConnection {
    private static let tunnelPath = "/_padserver/tunnel"
    private static let protocolVersion = "padserver-relay.v1"
    private static let unauthorizedStatus = 401
    private static let normalClosureCode = 1000
    private static let replacedCloseCode = 4000
    private static let protocolErrorCloseCode = 4001

    public nonisolated let frames: AsyncStream<RelayFrame>
    public nonisolated let stateChanges: AsyncStream<RelayConnectionState>

    private let connector: any RelaySocketConnecting
    private let frameContinuation: AsyncStream<RelayFrame>.Continuation
    private let stateContinuation: AsyncStream<RelayConnectionState>.Continuation
    private var currentState: RelayConnectionState = .disconnected
    private var generation = 0
    private var socket: (any RelaySocket)?
    private var receiveTask: Task<Void, Never>?

    public init() {
        self.init(connector: URLSessionRelaySocketConnector())
    }

    init(connector: any RelaySocketConnecting) {
        self.connector = connector
        (frames, frameContinuation) = AsyncStream.makeStream()
        (stateChanges, stateContinuation) = AsyncStream.makeStream()
    }

    public func state() -> RelayConnectionState {
        currentState
    }

    public func start(_ config: RelayConfig) async {
        teardown()
        let current = generation
        update(.connecting)
        let opened: any RelaySocket
        do {
            opened = try await connector.open(Self.makeRequest(config))
        } catch {
            guard current == generation else { return }
            update(Self.state(afterOpenFailure: error))
            return
        }
        guard current == generation else {
            opened.close(code: Self.normalClosureCode)
            return
        }
        socket = opened
        update(.connected)
        receiveTask = Task { await receiveLoop(opened, generation: current) }
    }

    public func stop() {
        teardown()
        update(.disconnected)
    }

    private func teardown() {
        generation += 1
        receiveTask?.cancel()
        receiveTask = nil
        let closing = socket
        socket = nil
        closing?.close(code: Self.normalClosureCode)
    }

    private func receiveLoop(_ socket: any RelaySocket, generation current: Int) async {
        do {
            while true {
                let message = try await socket.receive()
                guard current == generation else { return }
                guard case .data(let data) = message else { continue }
                if !deliver(data, from: socket) { return }
            }
        } catch {
            guard current == generation else { return }
            self.socket = nil
            update(Self.state(afterReceiveFailure: error))
        }
    }

    private func deliver(_ data: Data, from socket: any RelaySocket) -> Bool {
        do {
            frameContinuation.yield(try RelayFrame.decode(data))
        } catch let error as RelayFrameError where error.level == .request {
            return true
        } catch {
            self.socket = nil
            update(.reconnecting)
            socket.close(code: Self.protocolErrorCloseCode)
            return false
        }
        return true
    }

    private func update(_ state: RelayConnectionState) {
        currentState = state
        stateContinuation.yield(state)
    }

    private static func makeRequest(_ config: RelayConfig) -> URLRequest {
        var components = URLComponents(url: config.url, resolvingAgainstBaseURL: false) ?? URLComponents()
        components.scheme = "wss"
        components.path = tunnelPath
        components.query = nil
        components.fragment = nil
        var request = URLRequest(url: components.url ?? config.url)
        request.setValue("Bearer \(config.token.value)", forHTTPHeaderField: "Authorization")
        request.setValue(protocolVersion, forHTTPHeaderField: "Sec-WebSocket-Protocol")
        return request
    }

    private static func state(afterOpenFailure error: any Error) -> RelayConnectionState {
        if case RelaySocketError.upgradeRejected(let status) = error, status == unauthorizedStatus {
            return .unauthorized
        }
        return .reconnecting
    }

    private static func state(afterReceiveFailure error: any Error) -> RelayConnectionState {
        if case RelaySocketError.closed(let code) = error, code == replacedCloseCode {
            return .replaced
        }
        return .reconnecting
    }
}
