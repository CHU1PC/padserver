import Foundation
import Synchronization
import Testing
@testable import padctl

struct CapturedRequest: Sendable {
    let method: String
    let path: String
    let authorization: String?
    let contentType: String?
    let body: Data
}

enum StubResponse: Sendable {
    case json(status: Int, body: String)
    case chunks(status: Int, [Data])
    case failure(URLError)
}

// URLProtocol は session ごとに生成されるため, host をキーにして試験ごとに応答と記録を分ける.
final class StubServer: Sendable {
    private let host = "stub-\(UUID().uuidString.lowercased()).example.com"
    private let log = RequestLog()

    init(_ response: StubResponse) {
        let log = log
        StubURLProtocol.register(host: host) { request in
            log.append(request)
            return response
        }
    }

    deinit {
        StubURLProtocol.unregister(host: host)
    }

    var requests: [CapturedRequest] {
        log.requests
    }

    func makeClient(token: String = "dummy-token") throws -> AdminClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        let config = try PadctlConfig(serverURL: #require(URL(string: "https://\(host)")))
        return try AdminClient(
            configStore: StubServerConfigStore(config: config),
            tokenStore: StubServerTokenStore(token: token),
            session: URLSession(configuration: configuration)
        )
    }
}

private final class RequestLog: Sendable {
    private let storage = Mutex<[CapturedRequest]>([])

    var requests: [CapturedRequest] {
        storage.withLock { $0 }
    }

    func append(_ request: CapturedRequest) {
        storage.withLock { $0.append(request) }
    }
}

struct StubServerConfigStore: ConfigStore {
    let config: PadctlConfig?

    func load() throws -> PadctlConfig? {
        config
    }

    func save(_ config: PadctlConfig?) throws {
        // 試験では保存しない.
    }
}

struct StubServerTokenStore: TokenStore {
    let token: String?

    func load() throws -> String? {
        token
    }

    func save(_ token: String?) throws {
        // 試験では保存しない.
    }
}

class StubURLProtocol: URLProtocol {
    typealias Handler = @Sendable (CapturedRequest) -> StubResponse

    private static let bodyBufferSize = 4_096
    private static let handlers = Mutex<[String: Handler]>([:])

    static func register(host: String, handler: @escaping Handler) {
        handlers.withLock { $0[host] = handler }
    }

    static func unregister(host: String) {
        handlers.withLock { $0[host] = nil }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
            let handler = Self.handlers.withLock({ $0[host] })
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotFindHost))
            return
        }
        let captured = CapturedRequest(
            method: request.httpMethod ?? "",
            path: url.path(percentEncoded: true),
            authorization: request.value(forHTTPHeaderField: "Authorization"),
            contentType: request.value(forHTTPHeaderField: "Content-Type"),
            body: readBody()
        )
        respond(handler(captured), url: url)
    }

    override func stopLoading() {
        // 応答は startLoading で送り切るため, 中断する処理は無い.
    }

    private func respond(_ response: StubResponse, url: URL) {
        switch response {
        case .json(let status, let body):
            sendResponse(status: status, url: url, chunks: [Data(body.utf8)])

        case .chunks(let status, let chunks):
            sendResponse(status: status, url: url, chunks: chunks)

        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    private func sendResponse(status: Int, url: URL, chunks: [Data]) {
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        for chunk in chunks {
            client?.urlProtocol(self, didLoad: chunk)
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    private func readBody() -> Data {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: Self.bodyBufferSize)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else {
                break
            }
            data.append(buffer, count: count)
        }
        return data
    }
}
