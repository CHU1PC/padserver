import Foundation

public struct ImageSummary: Decodable, Equatable, Sendable {
    public let id: String
    public let repoTags: [String]
    public let size: Int

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case repoTags = "RepoTags"
        case size = "Size"
    }
}

extension ImageSummary {
    /// タグの無い image では RepoTags が null で返るので, 空の配列にする.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        repoTags = try container.decodeIfPresent([String].self, forKey: .repoTags) ?? []
        size = try container.decode(Int.self, forKey: .size)
    }
}

private struct ProgressLine: Decodable {
    struct Detail: Decodable {
        let message: String?
    }

    let error: String?
    let errorDetail: Detail?

    var failureMessage: String? {
        error ?? errorDetail?.message
    }
}

@available(macOS 13, iOS 16, *)
extension DockerClient {
    public enum ImageError: Error, Equatable, Sendable {
        case notFound
        case conflict
        case operationFailed(String)
    }

    private enum ImageConstants {
        static let okStatus = 200
        static let notFoundStatus = 404
        static let conflictStatus = 409
        static let newline = UInt8(ascii: "\n")
        // 取得と読み込みは, 大きな image だと応答が数分後になるので, 既定の 60 秒より長く待つ (1 日)
        static let transferTimeoutSeconds: TimeInterval = 86_400
    }

    public func listImages() async throws -> [ImageSummary] {
        let response = try await send(method: "GET", path: "/images/json")
        try Self.expect(response.status)
        do {
            return try JSONDecoder().decode([ImageSummary].self, from: response.body)
        } catch {
            throw ClientError.invalidResponse
        }
    }

    /// 進捗の行を最後まで読み, error があれば `operationFailed` を投げる.
    public func pullImage(_ image: String, tag: String = "latest") async throws {
        let query = [URLQueryItem(name: "fromImage", value: image), URLQueryItem(name: "tag", value: tag)]
        let response = try await send(
            method: "POST", path: "/images/create", query: query, timeout: ImageConstants.transferTimeoutSeconds)
        try Self.expect(response.status)
        try Self.checkProgress(response.body)
    }

    /// `docker save` の tar を, メモリに溜めずに送って読み込む.
    public func loadImage(fromFile tar: URL) async throws {
        let response = try await send(
            method: "POST", path: "/images/load", bodyFile: tar, timeout: ImageConstants.transferTimeoutSeconds)
        try Self.expect(response.status)
        try Self.checkProgress(response.body)
    }

    public func removeImage(name: String) async throws {
        let response = try await send(method: "DELETE", path: "/images/\(name)")
        try Self.expect(response.status)
    }

    private static func expect(_ status: Int) throws {
        switch status {
        case ImageConstants.okStatus: return
        case ImageConstants.notFoundStatus: throw ImageError.notFound
        case ImageConstants.conflictStatus: throw ImageError.conflict
        default: throw ClientError.unexpectedStatus(status)
        }
    }

    private static func checkProgress(_ body: Data) throws {
        let decoder = JSONDecoder()
        for line in body.split(separator: ImageConstants.newline) {
            let progress: ProgressLine
            do {
                progress = try decoder.decode(ProgressLine.self, from: Data(line))
            } catch {
                throw ClientError.invalidResponse
            }
            if let message = progress.failureMessage { throw ImageError.operationFailed(message) }
        }
    }
}
