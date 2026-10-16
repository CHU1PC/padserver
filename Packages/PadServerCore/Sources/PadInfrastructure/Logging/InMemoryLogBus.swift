import Foundation
import PadApplication
import PadDomain

public actor InMemoryLogBus: LogBus {
    // portの契約である直近1,000件を保持し、購読ごとの蓄積にも同じ上限を使います。
    private static let logCapacity = 1_000

    private var history: [LogEntry] = []
    private var subscribers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]

    public init() {
        // 引数がない初期化子を明示し、actorの生成形を公開します。
    }

    public func publish(_ entry: LogEntry) {
        history.append(entry)
        if history.count > Self.logCapacity {
            history.removeFirst(history.count - Self.logCapacity)
        }

        for continuation in subscribers.values {
            continuation.yield(entry)
        }
    }

    public func subscribe() -> AsyncStream<LogEntry> {
        let subscriberID = UUID()
        // bufferを無限に増やさず、遅い購読者では古い未読ログを破棄します。
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.logCapacity)
        )
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeSubscriber(subscriberID)
            }
        }

        subscribers[subscriberID] = continuation
        for entry in history {
            continuation.yield(entry)
        }
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }
}
