import Foundation
import PadDomain

public struct LogRow: Identifiable, Hashable, Sendable {
    public let id: Int
    public let timestamp: Date
    public let source: String
    public let level: LogLevel
    public let message: String
}

/// ログを到着順に溜めて, 画面に出す行へ変えます.
public struct LogFeedPresenter: Sendable {
    // LogBus の再生件数と同じにして, 画面の行が増え続けないようにします.
    public static let rowLimit = 1_000

    public private(set) var rows: [LogRow] = []
    private var nextID = 0

    public init() {
        // 明示した初期化子で公開 API を安定させます.
    }

    public mutating func append(_ entry: LogEntry) {
        rows.append(
            LogRow(
                id: nextID, timestamp: entry.timestamp, source: entry.source, level: entry.level,
                message: entry.message))
        nextID += 1
        if rows.count > Self.rowLimit {
            rows.removeFirst(rows.count - Self.rowLimit)
        }
    }
}
