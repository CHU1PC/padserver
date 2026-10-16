import Foundation
import PadDomain

public struct IssueToken: Sendable {
    // 管理 token は256ビットの乱数とし、推測が現実的でない長さを確保します。
    private static let tokenByteCount = 32

    private let secretStore: any SecretStore
    private let makeToken: @Sendable () -> AdminToken

    public init(secretStore: any SecretStore) {
        self.init(
            secretStore: secretStore,
            makeToken: {
                var generator = SystemRandomNumberGenerator()
                let value = (0..<Self.tokenByteCount).map { _ in
                    String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
                }.joined()
                return AdminToken(value)
            })
    }

    init(secretStore: any SecretStore, makeToken: @escaping @Sendable () -> AdminToken) {
        self.secretStore = secretStore
        self.makeToken = makeToken
    }

    public func callAsFunction() async throws -> AdminToken {
        let token = makeToken()
        try await secretStore.setAdminToken(token)
        return token
    }
}
