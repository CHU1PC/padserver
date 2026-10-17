import CryptoKit
import Foundation
import PadDomain

public struct IssuedShareLink: Hashable, Sendable {
    public let link: ShareLink
    public let secret: String

    public init(link: ShareLink, secret: String) {
        self.link = link
        self.secret = secret
    }
}

public enum ShareLinkError: Error, Equatable, Sendable {
    case fileNotFound
}

public struct ShareLinks: Sendable {
    // 共有リンクの秘密は256ビットの乱数とし、推測が現実的でない長さを確保します。
    private static let secretByteCount = 32

    private let fileStore: any FileStore
    private let linkStore: any ShareLinkStore
    private let timeSource: any TimeSource
    private let idGenerator: any IDGenerator
    private let makeSecret: @Sendable () -> String

    public init(
        fileStore: any FileStore,
        linkStore: any ShareLinkStore,
        timeSource: any TimeSource,
        idGenerator: any IDGenerator
    ) {
        self.init(
            fileStore: fileStore,
            linkStore: linkStore,
            timeSource: timeSource,
            idGenerator: idGenerator,
            makeSecret: {
                var generator = SystemRandomNumberGenerator()
                return (0..<Self.secretByteCount).map { _ in
                    String(format: "%02x", UInt8.random(in: UInt8.min...UInt8.max, using: &generator))
                }.joined()
            })
    }

    init(
        fileStore: any FileStore,
        linkStore: any ShareLinkStore,
        timeSource: any TimeSource,
        idGenerator: any IDGenerator,
        makeSecret: @escaping @Sendable () -> String
    ) {
        self.fileStore = fileStore
        self.linkStore = linkStore
        self.timeSource = timeSource
        self.idGenerator = idGenerator
        self.makeSecret = makeSecret
    }

    /// 秘密は発行時にだけ返し、保存するのは hash だけです。ファイルが無ければ `ShareLinkError.fileNotFound` を投げます。
    public func issue(fileName: String, validFor duration: TimeInterval) async throws -> IssuedShareLink {
        guard try await fileStore.file(named: fileName) != nil else {
            throw ShareLinkError.fileNotFound
        }
        let secret = makeSecret()
        let link = ShareLink(id: idGenerator.generate(), expiresAt: timeSource.now().addingTimeInterval(duration))
        try await linkStore.saveLink(
            StoredShareLink(link: link, fileName: fileName, secretHash: Self.secretHash(of: secret)))
        return IssuedShareLink(link: link, secret: secret)
    }

    public func revoke(id: UUID) async throws {
        try await linkStore.removeLink(id: id)
    }

    static func secretHash(of secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
