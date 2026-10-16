import Foundation
import PadDomain

/// 固定した日時を呼び出し側へ渡します。
public protocol TimeSource: Sendable {
    func now() -> Date
}

/// 呼び出し側で生成した UUID を渡します。
public protocol IDGenerator: Sendable {
    func generate() -> UUID
}

/// ログを発行し、直近のログを再生する購読 stream を返します。
public protocol LogBus: Sendable {
    /// ログを全ての購読者へ流します。
    func publish(_ entry: LogEntry) async

    /// 購読開始時に直近最大 1,000 件を再生します。消費側 Task の取消で購読を終了します。
    func subscribe() async -> AsyncStream<LogEntry>
}
