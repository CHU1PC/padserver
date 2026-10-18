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
}

/// 相互 TLS を要求する, 試験用の HTTP サーバー. 応答は path ごとに決める.
struct TLSTestServer: Sendable {
    private enum Constants {
        static let maximumRequestBytes = 65_536
        static let requestLineParts = 3
        static let pathIndex = 1
        static let notFoundStatus = 404
    }

    private enum ServerError: Error {
        case identityUnavailable
        case listenerStopped
    }

    private let listener: NWListener
    let port: UInt16

    static func start(credentials: GuestCredentials, routes: [String: TLSTestResponse]) async throws -> TLSTestServer {
        let options = try tlsOptions(credentials: credentials)
        let listener = try NWListener(using: NWParameters(tls: options, tcp: NWProtocolTCP.Options()))
        let queue = DispatchQueue(label: "TLSTestServer.listener")
        listener.newConnectionHandler = { connection in
            connection.start(queue: queue)
            receiveRequest(connection, routes: routes, buffer: Data())
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

    private static func receiveRequest(_ connection: NWConnection, routes: [String: TLSTestResponse], buffer: Data) {
        let maximum = Constants.maximumRequestBytes
        connection.receive(minimumIncompleteLength: 1, maximumLength: maximum) { data, _, _, error in
            guard error == nil, let data else {
                connection.cancel()
                return
            }
            let received = buffer + data
            guard let text = String(data: received, encoding: .utf8), text.contains("\r\n\r\n") else {
                receiveRequest(connection, routes: routes, buffer: received)
                return
            }
            respond(to: text, on: connection, routes: routes)
        }
    }

    private static func respond(to request: String, on connection: NWConnection, routes: [String: TLSTestResponse]) {
        let parts = request.split(separator: " ", maxSplits: Constants.requestLineParts - 1)
        let path = parts.count > Constants.pathIndex ? String(parts[Constants.pathIndex]) : ""
        let response = routes[path] ?? TLSTestResponse(status: Constants.notFoundStatus, body: "not found")
        let head =
            "HTTP/1.1 \(response.status) X\r\nContent-Length: \(response.body.utf8.count)\r\nConnection: close\r\n\r\n"
        connection.send(
            content: Data((head + response.body).utf8),
            completion: .contentProcessed { _ in connection.cancel() })
    }
}
