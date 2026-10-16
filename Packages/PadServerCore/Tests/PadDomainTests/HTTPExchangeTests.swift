import Foundation
import Testing

import PadDomain

@Test func requestHeadKeepsMethodURIHTTPVersionAndHeaders() {
    let head = HTTPRequestHead(
        method: "GET",
        uri: "/index.html?lang=en",
        version: "HTTP/1.1",
        headers: [HTTPHeader(name: "host", value: "example.com")]
    )

    #expect(head.method == "GET")
    #expect(head.uri == "/index.html?lang=en")
    #expect(head.version == "HTTP/1.1")
    #expect(head.headers == [HTTPHeader(name: "host", value: "example.com")])
}

@Test func responseHeadKeepsStatusHTTPVersionAndHeaders() {
    let head = HTTPResponseHead(
        status: 200,
        version: "HTTP/1.1",
        headers: [HTTPHeader(name: "content-type", value: "text/html")]
    )

    #expect(head.status == 200)
    #expect(head.version == "HTTP/1.1")
    #expect(head.headers == [HTTPHeader(name: "content-type", value: "text/html")])
}

@Test func requestAndResponseCarrySendablePullBasedBodyStreams() async {
    let source = ChunkSequence(chunks: [Data("first".utf8), Data("second".utf8)])
    let request = HTTPRequest(
        head: HTTPRequestHead(method: "POST", uri: "/upload", version: "HTTP/1.1", headers: []),
        body: source
    )
    let response = HTTPResponse(
        head: HTTPResponseHead(status: 200, version: "HTTP/1.1", headers: []),
        body: source
    )

    assertSendable(request)
    assertSendable(response)

    var requestIterator = request.body.makeAsyncIterator()
    var responseIterator = response.body.makeAsyncIterator()

    #expect(await requestIterator.next() == Data("first".utf8))
    #expect(await requestIterator.next() == Data("second".utf8))
    #expect(await requestIterator.next() == nil)
    #expect(await responseIterator.next() == Data("first".utf8))
    #expect(request.head.method == "POST")
    #expect(response.head.status == 200)
}

@Test func gatedBodyStreamProducesOnlyAfterNextDemandIsReleased() async {
    let stream = GatedBodyStream()
    let gate = stream.gate
    let demandEvents = gate.demandEvents
    var demandIterator = demandEvents.makeAsyncIterator()

    let firstChunk = Data("first".utf8)
    let firstRead = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    #expect(await demandIterator.next() != nil)
    #expect(await gate.generatedCount == 0)
    await gate.release(firstChunk)
    #expect(await firstRead.value == firstChunk)
    #expect(await gate.generatedCount == 1)

    let secondRead = Task {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
    }

    #expect(await demandIterator.next() != nil)
    #expect(await gate.generatedCount == 1)
    let secondChunk = Data("second".utf8)
    await gate.release(secondChunk)
    #expect(await secondRead.value == secondChunk)
    #expect(await gate.generatedCount == 2)
}

private func assertSendable<Value: Sendable>(_ value: Value) {
    _ = value
}

private struct ChunkSequence: HTTPBodyStream {
    typealias Element = Data

    let chunks: [Data]

    struct AsyncIterator: AsyncIteratorProtocol {
        let chunks: [Data]
        var index = 0

        mutating func next() async -> Data? {
            await Task.yield()
            guard index < chunks.count else {
                return nil
            }
            defer { index += 1 }
            return chunks[index]
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(chunks: chunks)
    }
}

private struct GatedBodyStream: HTTPBodyStream {
    typealias Element = Data

    let gate = BodyDemandGate()

    struct AsyncIterator: AsyncIteratorProtocol {
        let gate: BodyDemandGate

        mutating func next() async -> Data? {
            await gate.next()
        }
    }

    func makeAsyncIterator() -> AsyncIterator {
        AsyncIterator(gate: gate)
    }
}

private actor BodyDemandGate {
    private let demandContinuation: AsyncStream<Void>.Continuation
    let demandEvents: AsyncStream<Void>
    private var pending: CheckedContinuation<Data?, Never>?
    private(set) var generatedCount = 0

    init() {
        let (events, continuation) = AsyncStream<Void>.makeStream()
        demandEvents = events
        demandContinuation = continuation
    }

    func next() async -> Data? {
        demandContinuation.yield(())
        return await withCheckedContinuation { continuation in
            pending = continuation
        }
    }

    func release(_ chunk: Data) {
        generatedCount += 1
        pending?.resume(returning: chunk)
        pending = nil
    }
}
