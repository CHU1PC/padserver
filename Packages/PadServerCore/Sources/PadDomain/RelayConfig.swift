import Foundation

public struct RelayToken: CustomDebugStringConvertible, CustomReflectable, CustomStringConvertible, Hashable, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        "RelayToken(<redacted>)"
    }

    public var debugDescription: String {
        description
    }

    public var customMirror: Mirror {
        Mirror(self, children: [])
    }
}

public struct RelayConfig: CustomDebugStringConvertible, CustomStringConvertible, Hashable, Sendable {
    public enum ValidationError: Error {
        case invalidURL
        case unsupportedScheme
        case emptyToken
    }

    private static let allowedSchemes: Set<String> = ["wss", "https"]

    public let url: URL
    public let token: RelayToken

    /// relay の URL (wss または https で host を持つもの) と token を検証して作ります。
    public init(url: String, token: String) throws {
        guard let parsed = URL(string: url), let scheme = parsed.scheme?.lowercased() else {
            throw ValidationError.invalidURL
        }
        guard Self.allowedSchemes.contains(scheme) else {
            throw ValidationError.unsupportedScheme
        }
        guard let host = parsed.host(percentEncoded: false), !host.isEmpty else {
            throw ValidationError.invalidURL
        }
        guard !token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyToken
        }

        self.url = parsed
        self.token = RelayToken(token)
    }

    public var description: String {
        "RelayConfig(url: \(url.absoluteString), token: <redacted>)"
    }

    public var debugDescription: String {
        description
    }
}
