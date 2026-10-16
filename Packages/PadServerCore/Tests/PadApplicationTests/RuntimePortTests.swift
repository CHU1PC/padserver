import Foundation
import Testing

@testable import PadApplication
import PadDomain

// 同じ時刻を使い、時刻生成を試験結果から切り離します。
private let fixedTestTimestamp = Date(timeIntervalSince1970: 0)
// 直近1,000件の再生契約を境界まで確認します。
private let expectedReplayLimit = 1_000
// 終了通知が来ない回帰時に、試験を有限時間で失敗させます。
private let terminationTimeout: Duration = .seconds(1)

@Test func runtimePortsAcceptFixedTimeAndIDSources() {
    let timestamp = fixedTestTimestamp
    let releaseID = UUID(
        uuid: (0x8B, 0x2F, 0x10, 0x8E, 0x35, 0x5F, 0x4A, 0xC7, 0x90, 0xAE, 0x31, 0xF5, 0xA8, 0xAB, 0x6A, 0x74)
    )
    let clock: any TimeSource = FixedTimeSource(timestamp: timestamp)
    let idGenerator: any IDGenerator = FixedIDGenerator(id: releaseID)

    #expect(clock.now() == timestamp)
    #expect(ReleaseID(idGenerator.generate()) == ReleaseID(releaseID))
}

@Test func logBusReplaysOnlyTheMostRecentThousandEntries() async {
    let bus: any LogBus = ContractLogBus()

    for index in 0...expectedReplayLimit {
        await bus.publish(makeLogEntry(index: index))
    }

    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()

    let firstReplayedEntry = await iterator.next()
    var lastReplayedEntry: LogEntry?
    for _ in 1..<expectedReplayLimit {
        lastReplayedEntry = await iterator.next()
    }

    #expect(firstReplayedEntry?.message == "entry-1")
    #expect(lastReplayedEntry?.message == "entry-\(expectedReplayLimit)")
}

@Test func logBusStreamsEntriesPublishedAfterSubscription() async {
    let bus: any LogBus = ContractLogBus()
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()

    await bus.publish(makeLogEntry(index: 1))

    #expect(await iterator.next()?.message == "entry-1")
}

@Test func logBusStreamEndsWhenTheConsumingTaskIsCancelled() async {
    let bus = ContractLogBus()
    let terminationEvents = await bus.terminationEvents()
    let stream = await bus.subscribe()
    var iterator = stream.makeAsyncIterator()

    let consumer = Task {
        await iterator.next()
    }

    consumer.cancel()

    #expect(await consumer.value == nil)
    #expect(await nextValueWithinTimeout(from: terminationEvents) == 0)
    #expect(await bus.subscriptionCount() == 0)
}

private func nextValueWithinTimeout(from stream: AsyncStream<Int>) async -> Int? {
    await withTaskGroup(of: Int?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            do {
                try await Task.sleep(for: terminationTimeout)
                return nil
            } catch {
                return nil
            }
        }

        guard let value = await group.next() else {
            group.cancelAll()
            return nil
        }
        group.cancelAll()
        return value
    }
}

private func makeLogEntry(index: Int) -> LogEntry {
    LogEntry(
        timestamp: fixedTestTimestamp,
        source: "test",
        level: .info,
        message: "entry-\(index)"
    )
}

private struct FixedTimeSource: TimeSource {
    let timestamp: Date

    func now() -> Date {
        timestamp
    }
}

private struct FixedIDGenerator: IDGenerator {
    let id: UUID

    func generate() -> UUID {
        id
    }
}

private actor ContractLogBus: LogBus {
    private var entries: [LogEntry] = []
    private var continuations: [Int: AsyncStream<LogEntry>.Continuation] = [:]
    private var nextContinuationID = 0
    private var terminationEventContinuation: AsyncStream<Int>.Continuation?

    func terminationEvents() -> AsyncStream<Int> {
        let (stream, continuation) = AsyncStream<Int>.makeStream(bufferingPolicy: .bufferingNewest(1))
        terminationEventContinuation = continuation
        return stream
    }

    func subscriptionCount() -> Int {
        continuations.count
    }

    func publish(_ entry: LogEntry) {
        entries.append(entry)
        if entries.count > expectedReplayLimit {
            entries.removeFirst(entries.count - expectedReplayLimit)
        }

        for continuation in continuations.values {
            continuation.yield(entry)
        }
    }

    func subscribe() -> AsyncStream<LogEntry> {
        let id = nextContinuationID
        nextContinuationID += 1
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(
            bufferingPolicy: .bufferingNewest(expectedReplayLimit)
        )
        continuations[id] = continuation
        continuation.onTermination = { @Sendable [weak self] _ in
            Task {
                await self?.removeContinuation(id)
            }
        }

        for entry in entries {
            continuation.yield(entry)
        }

        return stream
    }

    private func removeContinuation(_ id: Int) {
        continuations[id] = nil
        terminationEventContinuation?.yield(id)
    }
}
