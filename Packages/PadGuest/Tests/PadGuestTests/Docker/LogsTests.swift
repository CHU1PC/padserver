import Foundation
@testable import PadGuest
import Testing

private let containerID = "e90e34656806"
private let logsPath = "/containers/\(containerID)/logs?follow=1&stdout=1&stderr=1&timestamps=0"

private func frame(_ type: UInt8, _ text: String) -> Data {
    let payload = Data(text.utf8)
    var length = UInt32(payload.count).bigEndian
    return Data([type, 0, 0, 0]) + Data(bytes: &length, count: MemoryLayout<UInt32>.size) + payload
}

private func chunk(_ stream: LogStream, _ text: String) -> LogChunk {
    LogChunk(stream: stream, data: Data(text.utf8))
}

private func withServer(
    routes: [String: TLSTestResponse],
    _ body: (DockerClient, RequestLog) async throws -> Void
) async throws {
    let credentials = try await makeTestCredentials()
    let log = RequestLog()
    let server = try await TLSTestServer.start(credentials: credentials, routes: routes, log: log)
    defer { server.stop() }
    try await body(DockerClient(hostPort: server.port, credentials: credentials), log)
}

private func collect(_ stream: AsyncThrowingStream<LogChunk, Error>) async throws -> [LogChunk] {
    var chunks: [LogChunk] = []
    for try await chunk in stream { chunks.append(chunk) }
    return chunks
}

private func concatenated(_ chunks: [LogChunk], _ stream: LogStream) -> Data {
    chunks.filter { $0.stream == stream }.reduce(Data()) { $0 + $1.data }
}

// MARK: - LogFrameParser

@Test
func parserReturnsNothingForEmptyInput() throws {
    var parser = LogFrameParser()

    #expect(try parser.append(Data()).isEmpty)
}

@Test
func parserWaitsForRestOfHeader() throws {
    var parser = LogFrameParser()
    let bytes = frame(1, "hello")

    #expect(try parser.append(bytes.prefix(8)).isEmpty)
    #expect(try parser.append(bytes.dropFirst(8)) == [chunk(.stdout, "hello")])
}

@Test
func parserHandlesHeaderSplitAcrossAppends() throws {
    var parser = LogFrameParser()
    let bytes = frame(2, "oops")

    #expect(try parser.append(bytes.prefix(3)).isEmpty)
    #expect(try parser.append(bytes.dropFirst(3).prefix(3)).isEmpty)
    #expect(try parser.append(bytes.dropFirst(6)) == [chunk(.stderr, "oops")])
}

@Test
func parserHandlesPayloadSplitAcrossAppends() throws {
    var parser = LogFrameParser()
    let bytes = frame(1, "abcdef")

    #expect(try parser.append(bytes.prefix(11)).isEmpty)
    #expect(try parser.append(bytes.dropFirst(11)) == [chunk(.stdout, "abcdef")])
}

@Test
func parserReturnsFrameWhenPayloadFitsLengthExactly() throws {
    var parser = LogFrameParser()

    #expect(try parser.append(frame(1, "x")) == [chunk(.stdout, "x")])
    #expect(try parser.append(Data()).isEmpty)
}

@Test
func parserReturnsEveryFrameDeliveredAtOnce() throws {
    var parser = LogFrameParser()
    let bytes = frame(1, "a") + frame(2, "b") + frame(1, "c")

    #expect(try parser.append(bytes) == [chunk(.stdout, "a"), chunk(.stderr, "b"), chunk(.stdout, "c")])
}

@Test
func parserKeepsTrailingPartialFrameForNextAppend() throws {
    var parser = LogFrameParser()
    let second = frame(2, "second")

    #expect(try parser.append(frame(1, "first") + second.prefix(10)) == [chunk(.stdout, "first")])
    #expect(try parser.append(second.dropFirst(10)) == [chunk(.stderr, "second")])
}

@Test
func parserAcceptsOneByteAtATime() throws {
    var parser = LogFrameParser()
    var chunks: [LogChunk] = []

    for byte in frame(1, "ab") + frame(2, "cd") {
        chunks += try parser.append(Data([byte]))
    }

    #expect(chunks == [chunk(.stdout, "ab"), chunk(.stderr, "cd")])
}

@Test
func parserSkipsEmptyPayloadFrame() throws {
    var parser = LogFrameParser()

    #expect(try parser.append(frame(1, "") + frame(1, "x")) == [chunk(.stdout, "x")])
}

@Test
func parserTreatsStdinTypeAsStdout() throws {
    var parser = LogFrameParser()

    #expect(try parser.append(frame(0, "in")) == [chunk(.stdout, "in")])
}

@Test
func parserRejectsUnknownStreamType() {
    var parser = LogFrameParser()

    #expect(throws: DockerClient.ClientError.invalidResponse) { try parser.append(frame(3, "x")) }
}

@Test
func parserRejectsOversizedFrameBeforePayloadArrives() {
    var parser = LogFrameParser()
    let header = Data([1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF])

    #expect(throws: DockerClient.ClientError.invalidResponse) { try parser.append(header) }
}

// MARK: - followLogs

@Test(.timeLimit(.minutes(1)))
func followLogsSplitsMultiplexedStreamAcrossReads() async throws {
    let whole = frame(1, "out line\n") + frame(2, "err line\n") + frame(1, "again\n")
    let parts = [whole.prefix(5), whole.dropFirst(5).prefix(12), whole.dropFirst(17)].map { Data($0) }
    let route = TLSTestResponse(status: 200, body: "", parts: parts)
    try await withServer(routes: [logsPath: route]) { client, log in
        let chunks = try await collect(client.followLogs(id: containerID))

        #expect(concatenated(chunks, .stdout) == Data("out line\nagain\n".utf8))
        #expect(concatenated(chunks, .stderr) == Data("err line\n".utf8))
        #expect(await log.requests == [RecordedRequest(method: "GET", path: logsPath, body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsPassesTailInQuery() async throws {
    let path = logsPath + "&tail=5"
    let route = TLSTestResponse(status: 200, body: "", parts: [frame(1, "x")])
    try await withServer(routes: [path: route]) { client, log in
        let chunks = try await collect(client.followLogs(id: containerID, tail: 5))

        #expect(concatenated(chunks, .stdout) == Data("x".utf8))
        #expect(await log.requests.map(\.path) == [path])
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsReturnsRawStreamAsStdoutForTTY() async throws {
    let parts = [Data("first\nse".utf8), Data("cond\ntail".utf8)]
    try await withServer(routes: [logsPath: TLSTestResponse(status: 200, body: "", parts: parts)]) { client, _ in
        let chunks = try await collect(client.followLogs(id: containerID, tty: true))

        #expect(chunks.allSatisfy { $0.stream == .stdout })
        #expect(concatenated(chunks, .stdout) == Data("first\nsecond\ntail".utf8))
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsThrowsNotFoundForUnknownContainer() async throws {
    try await withServer(routes: [logsPath: TLSTestResponse(status: 404, body: "")]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.notFound) {
            try await collect(client.followLogs(id: containerID))
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsThrowsUnexpectedStatus() async throws {
    try await withServer(routes: [logsPath: TLSTestResponse(status: 500, body: "")]) { client, _ in
        await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) {
            try await collect(client.followLogs(id: containerID))
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsThrowsOnInvalidStreamType() async throws {
    let route = TLSTestResponse(status: 200, body: "", parts: [frame(9, "x")])
    try await withServer(routes: [logsPath: route]) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) {
            try await collect(client.followLogs(id: containerID))
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsThrowsWhenConnectionFails() async throws {
    let credentials = try await makeTestCredentials()
    let server = try await TLSTestServer.start(credentials: credentials, routes: [:])
    let port = server.port
    server.stop()
    let client = try DockerClient(hostPort: port, credentials: credentials)

    await #expect(throws: DockerClient.ClientError.connectionFailed) {
        try await collect(client.followLogs(id: containerID))
    }
}

@Test(.timeLimit(.minutes(1)))
func followLogsClosesConnectionWhenCancelled() async throws {
    let route = TLSTestResponse(status: 200, body: "", parts: [frame(1, "first")], holdOpen: true)
    try await withServer(routes: [logsPath: route]) { client, log in
        let task = Task<LogChunk?, Error> {
            for try await chunk in client.followLogs(id: containerID) {
                return chunk
            }
            return nil
        }
        let first = try await task.value
        #expect(first == chunk(.stdout, "first"))

        while await log.closedCount == 0 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await log.closedCount == 1)
    }
}
