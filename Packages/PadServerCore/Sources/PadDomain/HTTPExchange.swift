import Foundation

public struct HTTPHeader: Hashable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

public struct HTTPRequestHead: Hashable, Sendable {
    public let method: String
    public let uri: String
    public let version: String
    public let headers: [HTTPHeader]

    public init(method: String, uri: String, version: String, headers: [HTTPHeader]) {
        self.method = method
        self.uri = uri
        self.version = version
        self.headers = headers
    }
}

public struct HTTPResponseHead: Hashable, Sendable {
    public let status: Int
    public let version: String
    public let headers: [HTTPHeader]

    public init(status: Int, version: String, headers: [HTTPHeader]) {
        self.status = status
        self.version = version
        self.headers = headers
    }
}

/// 呼び出し側の `next()` 1 回につき、本文 chunk を最大 1 個供給する契約です。
/// 要求されていない後続 chunk の先読みとバッファリングは許容しません。
///
/// この型制約は `AsyncSequence` と `Sendable` の適合だけを確認し、供給量や先読みを
/// 強制しません。各 stream 実装はこの契約を守る必要があり、具体的な transport の
/// backpressure は後続の実装と検証で確認します。
public protocol HTTPBodyStream: AsyncSequence, Sendable where Element == Data {}

public struct HTTPRequest<Body: HTTPBodyStream>: Sendable {
    public let head: HTTPRequestHead
    public let body: Body

    public init(head: HTTPRequestHead, body: Body) {
        self.head = head
        self.body = body
    }
}

public struct HTTPResponse<Body: HTTPBodyStream>: Sendable {
    public let head: HTTPResponseHead
    public let body: Body

    public init(head: HTTPResponseHead, body: Body) {
        self.head = head
        self.body = body
    }
}
