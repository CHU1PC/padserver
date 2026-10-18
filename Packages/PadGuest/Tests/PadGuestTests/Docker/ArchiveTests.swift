import Foundation
@testable import PadGuest
import Testing

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

private func respond(_ status: Int, _ body: String = "") -> TLSTestResponse {
    TLSTestResponse(status: status, body: body)
}

private func withTarFile(_ content: String, _ body: (URL) async throws -> Void) async throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
    try Data(content.utf8).write(to: url)
    defer {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            Issue.record(error)
        }
    }
    try await body(url)
}

@Test(.timeLimit(.minutes(1)))
func putArchiveSendsPutWithFileBodyAsIs() async throws {
    let content = String(repeating: "0123456789abcdef", count: 16_384)
    try await withTarFile(content) { tar in
        try await withServer(routes: ["/containers/abc/archive?path=/app": respond(200)]) { client, log in
            try await client.putArchive(containerID: "abc", path: "/app", fromFile: tar)

            let requests = await log.requests
            #expect(requests.map(\.method) == ["PUT"])
            #expect(requests.map(\.path) == ["/containers/abc/archive?path=/app"])
            #expect(requests.first?.body == content)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func putArchivePercentEncodesPath() async throws {
    let encoded = "/containers/abc/archive?path=/srv/my%20app/%E6%97%A5%E6%9C%AC%E8%AA%9E"
    try await withTarFile("x") { tar in
        try await withServer(routes: [encoded: respond(200)]) { client, log in
            try await client.putArchive(containerID: "abc", path: "/srv/my app/日本語", fromFile: tar)

            #expect(await log.requests.map(\.path) == [encoded])
        }
    }
}

private enum Status {
    static let badRequest = 400
    static let forbidden = 403
    static let notFound = 404
}

private let errorStatuses: [(Int, DockerClient.ArchiveError)] = [
    (Status.notFound, .notFound),
    (Status.forbidden, .readOnlyFileSystem),
    (Status.badRequest, .invalidRequest),
]

@Test(.timeLimit(.minutes(1)), arguments: errorStatuses)
func putArchiveMapsErrorStatus(status: Int, expected: DockerClient.ArchiveError) async throws {
    try await withTarFile("x") { tar in
        try await withServer(routes: ["/containers/abc/archive?path=/app": respond(status)]) { client, _ in
            await #expect(throws: expected) {
                try await client.putArchive(containerID: "abc", path: "/app", fromFile: tar)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func putArchiveRejectsOtherStatus() async throws {
    try await withTarFile("x") { tar in
        try await withServer(routes: ["/containers/abc/archive?path=/app": respond(500)]) { client, _ in
            await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) {
                try await client.putArchive(containerID: "abc", path: "/app", fromFile: tar)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func putArchiveFailsWhenFileIsMissing() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
    try await withServer(routes: ["/containers/abc/archive?path=/app": respond(200)]) { client, log in
        await #expect(throws: DockerClient.ClientError.bodyFileUnreadable) {
            try await client.putArchive(containerID: "abc", path: "/app", fromFile: missing)
        }
        #expect(await log.requests.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func putArchiveDoesNotSendJSONContentType() async throws {
    try await withTarFile("tar") { tar in
        try await withServer(routes: ["/containers/abc/archive?path=/app": respond(200)]) { client, log in
            try await client.putArchive(containerID: "abc", path: "/app", fromFile: tar)

            #expect(await log.requests.first?.contentType != "application/json")
        }
    }
}
