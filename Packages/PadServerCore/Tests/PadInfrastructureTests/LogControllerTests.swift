import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import Testing

private func makeApplication(logBus: any LogBus) -> Application<RouterResponder<BasicRequestContext>> {
    let router = Router(context: BasicRequestContext.self)
    LogController(logBus: logBus).addRoutes(to: router)
    return Application(responder: router.buildResponder())
}

private func entry(_ message: String, second: Int, level: LogLevel = .info) -> LogEntry {
    LogEntry(
        timestamp: Date(timeIntervalSince1970: TimeInterval(second)), source: "web", level: level, message: message)
}

private actor TrackingLogBus: LogBus {
    private let inner = PadInfrastructure.InMemoryLogBus()
    private(set) var subscribed = false
    private(set) var terminated = false
    private var live: AsyncStream<LogEntry>.Continuation?

    func publish(_ entry: LogEntry) async {
        await inner.publish(entry)
    }

    func subscribe() async -> AsyncStream<LogEntry> {
        let source = await inner.subscribe()
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream()
        continuation.onTermination = { @Sendable _ in
            Task { await self.markTerminated() }
        }
        live = continuation
        subscribed = true
        Task {
            for await item in source { continuation.yield(item) }
        }
        return stream
    }

    private func markTerminated() {
        terminated = true
    }
}

@Test func logControllerStreamsReplayedEntriesAsNDJSON() async throws {
    let bus = PadInfrastructure.InMemoryLogBus()
    await bus.publish(entry("Started", second: 1_792_240_496))
    await bus.publish(entry("Failed\nbadly", second: 1_792_240_497, level: .error))

    let streamTask = Task {
        try await makeApplication(logBus: bus).test(.router) { client in
            try await client.execute(uri: "/v1/logs/stream", method: .get) { response in
                #expect(response.status == .ok)
                #expect(response.headers[.contentType] == "application/x-ndjson")
                return String(buffer: response.body)
            }
        }
    }
    try await Task.sleep(for: .milliseconds(200))
    streamTask.cancel()
    let text = try await streamTask.value

    let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
    #expect(lines.count == 3)
    #expect(text.hasSuffix("\n"))
    let decoder = AdminAPIJSON.makeDecoder()
    let decoded = try lines.dropLast().map { try decoder.decode(LogEntry.self, from: Data($0.utf8)) }
    #expect(
        decoded == [
            entry("Started", second: 1_792_240_496),
            entry("Failed\nbadly", second: 1_792_240_497, level: .error),
        ])
    #expect(lines[0].contains("\"timestamp\":\"2026-10-17T"))
}

@Test func logControllerSendsNewEntriesAfterReplayInArrivalOrder() async throws {
    let bus = PadInfrastructure.InMemoryLogBus()
    await bus.publish(entry("old", second: 1))

    let streamTask = Task {
        try await makeApplication(logBus: bus).test(.router) { client in
            try await client.execute(uri: "/v1/logs/stream", method: .get) { String(buffer: $0.body) }
        }
    }
    try await Task.sleep(for: .milliseconds(200))
    await bus.publish(entry("new1", second: 3))
    await bus.publish(entry("new2", second: 2))
    try await Task.sleep(for: .milliseconds(200))
    streamTask.cancel()
    let text = try await streamTask.value

    let decoder = AdminAPIJSON.makeDecoder()
    let messages = try text.split(separator: "\n").map {
        try decoder.decode(LogEntry.self, from: Data($0.utf8)).message
    }
    #expect(messages == ["old", "new1", "new2"])
}

@Test func logControllerReleasesSubscriptionWhenConnectionEnds() async throws {
    let bus = TrackingLogBus()
    await bus.publish(entry("Started", second: 1))

    let streamTask = Task {
        try await makeApplication(logBus: bus).test(.router) { client in
            try await client.execute(uri: "/v1/logs/stream", method: .get) { $0.status }
        }
    }
    while await !bus.subscribed {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await bus.terminated == false)

    streamTask.cancel()
    _ = await streamTask.result
    for _ in 0..<100 where await !bus.terminated {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(await bus.terminated == true)
}
