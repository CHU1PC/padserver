import PadApplication
import PadDomain

public actor InMemoryLogBus: LogBus {
    // Runtime port の replay 契約である直近 1,000 件を保持します。
    private static let replayLimit = 1_000

    private var history: [LogEntry] = []
    private var subscribers: [Int: AsyncStream<LogEntry>.Continuation] = [:]
    private var nextSubscriberID = 0

    public init() {
        // 明示した初期化子で公開 API を安定させます。
    }

    public func publish(_ entry: LogEntry) {
        history.append(entry)
        if history.count > Self.replayLimit {
            history.removeFirst(history.count - Self.replayLimit)
        }

        for continuation in subscribers.values {
            continuation.yield(entry)
        }
    }

    public func subscribe() -> AsyncStream<LogEntry> {
        let subscriberID = nextSubscriberID
        nextSubscriberID += 1
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(
            bufferingPolicy: .bufferingNewest(Self.replayLimit)
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

    private func removeSubscriber(_ id: Int) {
        subscribers[id] = nil
    }
}
