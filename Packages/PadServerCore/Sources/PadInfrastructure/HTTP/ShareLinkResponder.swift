import CryptoKit
import Foundation
import Hummingbird
import PadApplication

public struct ShareLinkResponder: Sendable {
    private let fileStore: any FileStore
    private let linkStore: any ShareLinkStore
    private let timeSource: any TimeSource

    public init(fileStore: any FileStore, linkStore: any ShareLinkStore, timeSource: any TimeSource) {
        self.fileStore = fileStore
        self.linkStore = linkStore
        self.timeSource = timeSource
    }

    /// 秘密が未知、期限切れ、失効、またはファイルが無いときは 404 を返します。
    public func respond(to request: Request, secret: String) async throws -> Response {
        guard let record = try await linkStore.link(forSecretHash: Self.secretHash(of: secret)),
            record.link.isValid(at: timeSource.now()),
            let file = try await fileStore.file(named: record.fileName),
            let stream = try await fileStore.openFile(named: record.fileName)
        else {
            return Response(status: .notFound)
        }
        let contentType =
            MediaType.getMediaType(forExtension: (record.fileName as NSString).pathExtension)?.description
            ?? MediaType.applicationBinary.description
        var response = RangeResponder().respond(to: request, stream: stream, size: file.size)
        response.headers[.contentType] = contentType
        response.headers[.acceptRanges] = "bytes"
        return response
    }

    private static func secretHash(of secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
