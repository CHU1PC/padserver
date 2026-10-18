import Foundation
@preconcurrency import Security

public struct DockerVersion: Decodable, Equatable, Sendable {
    public let version: String
    public let apiVersion: String

    private enum CodingKeys: String, CodingKey {
        case version = "Version"
        case apiVersion = "ApiVersion"
    }
}

/// 転送された host の port 経由で, 相互 TLS の Docker Engine API に繋ぐ.
@available(macOS 13, iOS 16, *)
public final class DockerClient: Sendable {
    public enum ClientError: Error, Equatable, Sendable {
        case invalidCredentials
        case connectionFailed
        case unexpectedStatus(Int)
        case invalidResponse
    }

    private enum Constants {
        static let okStatus = 200
    }

    private let baseURL: URL
    private let session: URLSession

    public init(hostPort: UInt16, credentials: GuestCredentials) throws {
        let identity: SecIdentity
        let caCertificate: SecCertificate
        do {
            identity = try PKCS12Identity.make(
                certificatePEM: credentials.clientCertificatePEM, keyPEM: credentials.clientKeyPEM)
            caCertificate = try PKCS12Identity.certificate(pem: credentials.caCertificatePEM)
        } catch {
            throw ClientError.invalidCredentials
        }
        guard let baseURL = URL(string: "https://127.0.0.1:\(hostPort)") else { throw ClientError.invalidCredentials }
        self.baseURL = baseURL
        session = URLSession(
            configuration: .ephemeral, delegate: TLSDelegate(identity: identity, caCertificate: caCertificate),
            delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func version() async throws -> DockerVersion {
        let data = try await get("/version")
        do {
            return try JSONDecoder().decode(DockerVersion.self, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    public func ping() async throws {
        let data = try await get("/_ping")
        guard String(data: data, encoding: .utf8) == "OK" else { throw ClientError.invalidResponse }
    }

    private func get(_ path: String) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(from: baseURL.appendingPathComponent(path))
        } catch {
            throw ClientError.connectionFailed
        }
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        guard http.statusCode == Constants.okStatus else { throw ClientError.unexpectedStatus(http.statusCode) }
        return data
    }
}

@available(macOS 13, iOS 16, *)
private final class TLSDelegate: NSObject, URLSessionDelegate, Sendable {
    private let identity: SecIdentity
    private let caCertificate: SecCertificate

    init(identity: SecIdentity, caCertificate: SecCertificate) {
        self.identity = identity
        self.caCertificate = caCertificate
    }

    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        switch challenge.protectionSpace.authenticationMethod {
        case NSURLAuthenticationMethodClientCertificate:
            completionHandler(.useCredential, URLCredential(identity: identity, certificates: nil, persistence: .none))

        case NSURLAuthenticationMethodServerTrust:
            guard let trust = challenge.protectionSpace.serverTrust else {
                completionHandler(.cancelAuthenticationChallenge, nil)
                return
            }
            // SSL ポリシーは 398 日を超える証明書を拒むので, 10 年の端末鍵のために基本ポリシーで検証する
            SecTrustSetPolicies(trust, SecPolicyCreateBasicX509())
            SecTrustSetAnchorCertificates(trust, [caCertificate] as CFArray)
            SecTrustSetAnchorCertificatesOnly(trust, true)
            if SecTrustEvaluateWithError(trust, nil) {
                completionHandler(.useCredential, URLCredential(trust: trust))
            } else {
                completionHandler(.cancelAuthenticationChallenge, nil)
            }

        default:
            completionHandler(.performDefaultHandling, nil)
        }
    }
}
