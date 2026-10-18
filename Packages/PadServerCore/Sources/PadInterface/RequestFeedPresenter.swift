import Foundation
import PadDomain

public struct RequestFeedRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let timestamp: Date
    public let host: String
    public let path: String
    public let status: Int
    public let durationMilliseconds: Double
    public let project: String?

    // 4xx と 5xx を失敗として色分けする.
    private static let firstFailureStatus = 400

    public var isFailure: Bool {
        status >= Self.firstFailureStatus
    }
}

/// 配信の log (source が `serving`) から, 直近の要求を新しい順に並べます.
public struct RequestFeedPresenter: Sendable {
    private static let servingSource = "serving"
    // 1 画面で見渡せる件数として 100 件に絞り, 古い要求は捨てる.
    private static let rowLimit = 100

    public private(set) var rows: [RequestFeedRow] = []
    private var nextID = 0

    public init() {
        // 引数がない初期化子を明示し, 生成形を公開します.
    }

    public mutating func receive(_ entry: LogEntry) {
        guard entry.source == Self.servingSource, let row = Self.makeRow(from: entry, id: nextID) else { return }
        nextID += 1
        let index = rows.firstIndex { $0.timestamp <= row.timestamp } ?? rows.endIndex
        rows.insert(row, at: index)
        if rows.count > Self.rowLimit {
            rows.removeLast(rows.count - Self.rowLimit)
        }
    }

    /// `host=<host> path=<path> status=<status> duration_ms=<ms>` の形だけを受け付けます.
    private static func makeRow(from entry: LogEntry, id: Int) -> RequestFeedRow? {
        var fields = entry.message.split(separator: " ", omittingEmptySubsequences: false).makeIterator()
        guard let host = fields.next().flatMap({ value(of: $0, key: "host") }),
            let path = fields.next().flatMap({ value(of: $0, key: "path") }),
            let status = fields.next().flatMap({ value(of: $0, key: "status") }).flatMap({ Int($0) }),
            let duration = fields.next().flatMap({ value(of: $0, key: "duration_ms") }).flatMap({ Double($0) }),
            fields.next() == nil
        else { return nil }
        return RequestFeedRow(
            id: id, timestamp: entry.timestamp, host: String(host), path: String(path), status: status,
            durationMilliseconds: duration, project: entry.project)
    }

    private static func value(of part: Substring, key: String) -> Substring? {
        let prefix = "\(key)="
        guard part.hasPrefix(prefix) else { return nil }
        return part.dropFirst(prefix.count)
    }
}
