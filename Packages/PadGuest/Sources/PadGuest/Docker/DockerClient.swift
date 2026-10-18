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
        case bodyFileUnreadable
    }

    private enum Constants {
        static let okStatus = 200
        static let forbiddenStatus = 403
        // 追尾は応答が途切れることがあるので, 既定の 60 秒より長く待つ (1 日)
        static let streamingTimeout: TimeInterval = 86_400
    }

    private let baseURL: URL
    private let session: URLSession
    private let tlsDelegate: TLSDelegate

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
        tlsDelegate = TLSDelegate(identity: identity, caCertificate: caCertificate)
        session = URLSession(configuration: .ephemeral, delegate: tlsDelegate, delegateQueue: nil)
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
        let response = try await send(method: "GET", path: path)
        guard response.status == Constants.okStatus else { throw ClientError.unexpectedStatus(response.status) }
        return response.body
    }

    /// 状態コードの判断は呼び出し側に任せる. 接続の失敗は `connectionFailed` にする.
    func send(
        method: String, path: String, query: [URLQueryItem] = [], body: Data? = nil, timeout: TimeInterval? = nil
    ) async throws -> (status: Int, body: Data) {
        var request = try makeRequest(method: method, path: path, query: query, timeout: timeout)
        request.httpBody = body
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ClientError.connectionFailed
        }
        return (try Self.status(of: response), data)
    }

    /// ファイルを本文として, メモリに溜めずに送る.
    func send(
        method: String, path: String, query: [URLQueryItem] = [], bodyFile: URL, timeout: TimeInterval? = nil
    ) async throws -> (status: Int, body: Data) {
        // 読めないファイルは URLSession が空の本文で送ってしまうので, 先に弾く
        guard FileManager.default.isReadableFile(atPath: bodyFile.path) else { throw ClientError.bodyFileUnreadable }
        let request = try makeRequest(method: method, path: path, query: query, timeout: timeout)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        } catch let error as URLError where error.code == .clientCertificateRequired {
            // 相互 TLS の接続で 403 を受けると, URLSession はこの error にしてしまう
            return (Constants.forbiddenStatus, Data())
        } catch {
            throw ClientError.connectionFailed
        }
        return (try Self.status(of: response), data)
    }

    /// 本文を溜めずに逐次受ける. ログの追尾専用で, 状態コードの判断は呼び出し側に任せる.
    func sendStreaming(
        method: String, path: String, query: [URLQueryItem] = []
    ) async throws -> (status: Int, bytes: URLSession.AsyncBytes) {
        let request = try makeRequest(method: method, path: path, query: query, timeout: Constants.streamingTimeout)
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: tlsDelegate)
        } catch {
            throw ClientError.connectionFailed
        }
        return (try Self.status(of: response), bytes)
    }

    private func makeRequest(
        method: String, path: String, query: [URLQueryItem], timeout: TimeInterval?
    ) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false)
        else { throw ClientError.invalidResponse }
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { throw ClientError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = method
        if let timeout { request.timeoutInterval = timeout }
        return request
    }

    private static func status(of response: URLResponse) throws -> Int {
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        return http.statusCode
    }
}

@available(macOS 13, iOS 16, *)
private final class TLSDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, Sendable {
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
        handle(challenge, completionHandler)
    }

    // 非同期 API に task の delegate を渡すと, 認証の問い合わせは session ではなくこちらに届く
    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        handle(challenge, completionHandler)
    }

    private func handle(
        _ challenge: URLAuthenticationChallenge,
        _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
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
