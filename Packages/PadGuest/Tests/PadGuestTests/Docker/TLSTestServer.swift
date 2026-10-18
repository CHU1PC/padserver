import Foundation
import Network
@testable import PadGuest
import Security

actor InMemoryCredentialStore: CredentialStore {
    private var stored: Data?

    func load() -> Data? {
        stored
    }

    func save(_ data: Data) {
        stored = data
    }
}

func makeTestCredentials() async throws -> GuestCredentials {
    try await GuestCredentialsProvider(store: InMemoryCredentialStore()).credentials()
}

struct TLSTestResponse: Sendable {
    let status: Int
    let body: String
    /// 空でなければ, Content-Length 無しで parts を少しずつ流す.
    var parts: [Data] = []
    /// true なら, parts を流した後も, 相手が閉じるまで接続を保つ.
    var holdOpen = false
}

struct RecordedRequest: Equatable, Sendable {
    let method: String
    let path: String
    let body: String
}

actor RequestLog {
    private(set) var requests: [RecordedRequest] = []

    private(set) var closedCount = 0

    func append(_ request: RecordedRequest) {
        requests.append(request)
    }

    func recordClosed() {
        closedCount += 1
    }
}

/// 相互 TLS を要求する, 試験用の HTTP サーバー. 応答は path ごとに決める.
struct TLSTestServer: Sendable {
    private enum Constants {
        static let maximumRequestBytes = 65_536
        static let requestLineParts = 3
        static let pathIndex = 1
        static let headerFieldParts = 2
        static let notFoundStatus = 404
        static let partIntervalMilliseconds = 30
    }

    private enum ServerError: Error {
        case identityUnavailable
        case listenerStopped
    }

    private let listener: NWListener
    let port: UInt16

    static func start(
        credentials: GuestCredentials, routes: [String: TLSTestResponse], log: RequestLog? = nil
    ) async throws -> TLSTestServer {
        let options = try tlsOptions(credentials: credentials)
        let listener = try NWListener(using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "TLSTestServer.listener")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receiveRequest(connection, routes: routes, log: log, buffer: Data())
        }
        let states = AsyncStream<NWListener.State> { continuation in
            listener.stateUpdateHandler = { continuation.yield($0) }
        }
        listener.start(queue: queue)
        for await state in states {
            switch state {
            case .ready:
                return TLSTestServer(listener: listener, port: listener.port?.rawValue ?? 0)

            case .failed(let error):
                throw error

            case .cancelled:
                throw ServerError.listenerStopped

            default:
                continue
            }
        }
        throw ServerError.listenerStopped
    }

    private static func tlsOptions(credentials: GuestCredentials) throws -> NWProtocolTLS.Options {
        let identity = try PKCS12Identity.make(
            certificatePEM: credentials.serverCertificatePEM, keyPEM: credentials.serverKeyPEM)
        let caCertificate = try PKCS12Identity.certificate(pem: credentials.caCertificatePEM)
        let options = NWProtocolTLS.Options()
        let security = options.securityProtocolOptions
        guard let secIdentity = sec_identity_create(identity) else { throw ServerError.identityUnavailable }
        sec_protocol_options_set_local_identity(security, secIdentity)
        sec_protocol_options_set_peer_authentication_required(security, true)
        sec_protocol_options_set_verify_block(
            security,
            { _, trust, complete in
                let reference = sec_trust_copy_ref(trust).takeRetainedValue()
                SecTrustSetPolicies(reference, SecPolicyCreateBasicX509())
                SecTrustSetAnchorCertificates(reference, [caCertificate] as CFArray)
                SecTrustSetAnchorCertificatesOnly(reference, true)
                complete(SecTrustEvaluateWithError(reference, nil))
            }, DispatchQueue(label: "TLSTestServer.verify"))

        return options
    }

    func stop() {
        listener.cancel()
    }

    private static func receiveRequest(
        _ connection: NWConnection, routes: [String: TLSTestResponse], log: RequestLog?, buffer: Data
    ) {
        let maximum = Constants.maximumRequestBytes
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let received = buffer + data
            guard let request = parse(received) else {
                receiveRequest(connection, routes: routes, log: log, buffer: received)
                return
            }
            respond(to: request, on: connection, routes: routes, log: log)
        }
    }

    /// head と本文 (Content-Length の分) が揃うまでは nil を返す.
    private static func parse(_ data: Data) -> RecordedRequest? {
        guard let text = String(data: data, encoding: .utf8), let separator = text.range(of: "\r\n\r\n") else {
            return nil
        }
        let head = text[..<separator.lowerBound]
        let body = String(text[separator.upperBound...])
        let contentLength =
            head.split(separator: "\r\n")
            .compactMap { line -> Int? in
                let field = line.split(separator: ":", maxSplits: 1)
                guard field.count == Constants.headerFieldParts, field[0].lowercased() == "content-length" else {
                    return nil
                }
                return Int(field[1].trimmingCharacters(in: .whitespaces))
            }
            .first ?? 0
        guard body.utf8.count >= contentLength else { return nil }
        let requestLine = (head.split(separator: "\r\n").first ?? "").split(
            separator: " ", maxSplits: Constants.requestLineParts - 1)
        let method = requestLine.first.map(String.init) ?? ""
        let path = requestLine.count > Constants.pathIndex ? String(requestLine[Constants.pathIndex]) : ""
        return RecordedRequest(method: method, path: path, body: body)
    }

    private static func respond(
        to request: RecordedRequest, on connection: NWConnection, routes: [String: TLSTestResponse],
        log: RequestLog?
    ) {
        let response = routes[request.path] ?? TLSTestResponse(status: Constants.notFoundStatus, body: "not found")
        if !response.parts.isEmpty {
            stream(response, on: connection, request: request, log: log)
            return
        }
        let head =
            "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n"
        Task {
            await log?.append(request)
            connection.send(
                content: Data((head + response.body).utf8),
                completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private static func stream(
        _ response: TLSTestResponse, on connection: NWConnection, request: RecordedRequest, log: RequestLog?
    ) {
        let head =
            "HTTP/1.1 \(response.status) X\r\nContent-Type: application/vnd.docker.raw-stream\r\n"
            + "Connection: close\r\n\r\n"
        Task {
            await log?.append(request)
            connection.send(content: Data(head.utf8), completion: .idempotent)
            for part in response.parts {
                do {
                    try await Task.sleep(for: .milliseconds(Constants.partIntervalMilliseconds))
                } catch {
                    return
                }
                connection.send(content: part, completion: .idempotent)
            }
            guard response.holdOpen else {
                connection.send(
                    content: nil, isComplete: true, completion: .contentProcessed { _ in connection.cancel() })
                return
            }
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in
                Task { await log?.recordClosed() }
                connection.cancel()
            }
        }
    }
}
