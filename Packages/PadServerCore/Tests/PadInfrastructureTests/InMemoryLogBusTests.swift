import Foundation
import Testing

@testable import PadInfrastructure
import PadApplication
import PadDomain

// 時刻を固定し、再生順の試験結果を実時間から切り離します。
private let fixedTimestamp = Date(timeIntervalSince1970: 0)
// 履歴と購読bufferの契約上限を確認します。
private let logCapacity = 1_000
// 回帰時にstream待ちで試験が止まらないようにします。
private let operationTimeout: Duration = .seconds(1)
// onTerminationの解除Taskを最大1秒だけ待ちます。
private let subscriberRemovalPollMilliseconds = 10
private let subscriberRemovalPollInterval: Duration = .milliseconds(subscriberRemovalPollMilliseconds)
// 100回の確認で、解除callbackを最大1秒待ちます。
private let subscriberRemovalPollAttempts = 100

private enum TimedResult<Value: Sendable>: Sendable {
    case value(Value)
    case ended
    case timedOut
}

@Test func replaysOnlyTheLatestThousandEntriesInPublishOrder() async {
    let bus: any LogBus = InMemoryLogBus()

    for index in 0...logCapacity {
        await bus.publish(makeEntry(index: index))
    }

    let stream = await bus.subscribe()
    let entries = await collectWithinTimeout(from: stream, count: logCapacity)

    #expect(entries.map(\.message) == (1...logCapacity).map { "entry-\($0)" })
}

@Test func publishesEachEntryToMultipleSubscribers() async {
    let bus: any LogBus = InMemoryLogBus()
    let firstStream = await bus.subscribe()
    let secondStream = await bus.subscribe()

    await bus.publish(makeEntry(index: 7))

    #expect(await nextValue(from: firstStream)?.message == "entry-7")
    #expect(await nextValue(from: secondStream)?.message == "entry-7")
}

@Test func slowSubscriberDropsOldBufferedEntriesWithoutBlockingAnotherSubscriber() async {
    let bus = InMemoryLogBus()
    let slowStream = await bus.subscribe()
    let fastStream = await bus.subscribe()
    var fastIterator = fastStream.makeAsyncIterator()

    for index in 0..<logCapacity {
        await bus.publish(makeEntry(index: index))
        #expect(await fastIterator.next()?.message == "entry-\(index)")
    }

    // 購読ごとのbufferは履歴と同じ1,000件を保ち、遅い購読者の古いログを破棄します。
    await bus.publish(makeEntry(index: logCapacity))
    let slowEntries = await collectWithinTimeout(from: slowStream, count: logCapacity)

    #expect(slowEntries.map(\.message) == (1...logCapacity).map { "entry-\($0)" })
    #expect(await fastIterator.next()?.message == "entry-\(logCapacity)")
}

@Test func cancellationUnregistersTheSubscriber() async {
    let bus = InMemoryLogBus()
    let stream = await bus.subscribe()
    let consumer = Task {
        for await _ in stream {
            // 受信側はログを処理せず、キャンセルまで購読を維持します。
        }
    }

    await Task.yield()
    consumer.cancel()
    await consumer.value

    #expect(await eventuallyHasSubscriberCount(0, bus: bus))
}

@Test func publishAtTheReplayBoundaryIsDeliveredExactlyOnceAndInOrder() async {
    let bus: any LogBus = InMemoryLogBus()
    for index in 0..<logCapacity - 1 {
        await bus.publish(makeEntry(index: index))
    }

    async let stream = bus.subscribe()
    async let finalPublish: Void = bus.publish(makeEntry(index: logCapacity - 1))
    let subscribedStream = await stream
    await finalPublish
    let entries = await collectWithinTimeout(from: subscribedStream, count: logCapacity)

    #expect(entries.map(\.message) == (0..<logCapacity).map { "entry-\($0)" })
}

private func collectWithinTimeout(from stream: AsyncStream<LogEntry>, count: Int) async -> [LogEntry] {
    await withTaskGroup(of: TimedResult<[LogEntry]>.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            var entries: [LogEntry] = []
            for _ in 0..<count {
                guard let entry = await iterator.next() else { break }
                entries.append(entry)
            }
            return .value(entries)
        }
        group.addTask {
            do {
                try await Task.sleep(for: operationTimeout)
                return .timedOut
            } catch {
                return .timedOut
            }
        }

        let result = await group.next()
        group.cancelAll()
        guard case let .value(entries) = result else { return [] }
        return entries
    }
}

private func nextValue(from stream: AsyncStream<LogEntry>) async -> LogEntry? {
    await withTaskGroup(of: TimedResult<LogEntry>.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            guard let entry = await iterator.next() else { return .ended }
            return .value(entry)
        }
        group.addTask {
            do {
                try await Task.sleep(for: operationTimeout)
                return .timedOut
            } catch {
                return .timedOut
            }
        }

        let result = await group.next()
        group.cancelAll()
        guard case let .value(entry) = result else { return nil }
        return entry
    }
}

private func eventuallyHasSubscriberCount(_ expectedCount: Int, bus: InMemoryLogBus) async -> Bool {
    for _ in 0..<subscriberRemovalPollAttempts {
        if await bus.subscriberCount == expectedCount { return true }
        do {
            try await Task.sleep(for: subscriberRemovalPollInterval)
        } catch {
            return false
        }
    }
    return false
}

private func makeEntry(index: Int) -> LogEntry {
    LogEntry(timestamp: fixedTimestamp, source: "test", level: .info, message: "entry-\(index)")
}
