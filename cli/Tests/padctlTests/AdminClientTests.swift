import Foundation
import PadApplication
import PadDomain
import PadInterface
import Testing
@testable import padctl

private let exampleProject = #"{"name":"example-site","kind":"staticSite"}"#
private let exampleRelease =
    #"{"id":"00000000-0000-4000-8000-000000000001","project":"example-site","state":"active"}"#
private let exampleStatus = #"{"project":\#(exampleProject),"activeRelease":\#(exampleRelease),"running":true}"#

private let validHash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

@Test func listProjectsSendsBearerTokenAndDecodesResponse() async throws {
    let server = StubServer(.json(status: 200, body: #"{"projects":[\#(exampleStatus)]}"#))
    let client = try server.makeClient(token: "dummy-token")

    let response = try await client.listProjects()

    let request = try #require(server.requests.first)
    #expect(request.method == "GET")
    #expect(request.path == "/v1/projects")
    #expect(request.authorization == "Bearer dummy-token")
    #expect(response.projects.count == 1)
    #expect(response.projects.first?.running == true)
}

@Test func startAndStopPostToProjectPathWithoutBody() async throws {
    let server = StubServer(.json(status: 200, body: exampleStatus))
    let client = try server.makeClient()
    let name = try ProjectName("example-site")

    let started = try await client.startProject(name)
    _ = try await client.stopProject(name)

    #expect(started.project.name == name)
    #expect(server.requests.map(\.method) == ["POST", "POST"])
    #expect(server.requests.map(\.path) == ["/v1/projects/example-site/start", "/v1/projects/example-site/stop"])
    #expect(server.requests.allSatisfy { $0.body.isEmpty })
}

@Test func diffDeploymentPostsManifestAndFilesAndDecodesMissingBlobs() async throws {
    let missing = #"{"missingBlobs":[{"path":"index.html","hash":"\#(validHash)"}]}"#
    let server = StubServer(.json(status: 200, body: missing))
    let client = try server.makeClient()
    let request = try makeDeploymentRequest()

    let response = try await client.diffDeployment(project: request.manifest.name, request: request)

    let sent = try #require(server.requests.first)
    #expect(sent.method == "POST")
    #expect(sent.path == "/v1/projects/example-site/deployments/diff")
    #expect(sent.contentType == "application/json")
    let decoded = try AdminAPIJSON.makeDecoder().decode(AdminDeploymentRequest.self, from: sent.body)
    #expect(decoded == request)
    #expect(response.missingBlobs.map(\.path) == ["index.html"])
}

@Test func commitDeploymentExpectsCreatedStatus() async throws {
    let body = #"{"project":\#(exampleProject),"release":\#(exampleRelease)}"#
    let server = StubServer(.json(status: 201, body: body))
    let client = try server.makeClient()
    let request = try makeDeploymentRequest()

    let response = try await client.commitDeployment(project: request.manifest.name, request: request)

    #expect(server.requests.first?.path == "/v1/projects/example-site/deployments")
    #expect(response.release.state == .active)
}

@Test func commitDeploymentRejectsUnexpectedSuccessStatus() async throws {
    let body = #"{"project":\#(exampleProject),"release":\#(exampleRelease)}"#
    let server = StubServer(.json(status: 200, body: body))
    let client = try server.makeClient()
    let request = try makeDeploymentRequest()

    await #expect(throws: AdminClientError.server(status: 200, code: nil, message: nil)) {
        try await client.commitDeployment(project: request.manifest.name, request: request)
    }
}

@Test(arguments: [201, 204])
func uploadBlobPutsFileContentAsOctetStream(status: Int) async throws {
    let server = StubServer(.json(status: status, body: ""))
    let client = try server.makeClient()
    let file = FileManager.default.temporaryDirectory.appending(path: "padctl-tests-\(UUID().uuidString)")
    try Data("hello".utf8).write(to: file)
    defer {
        do {
            try FileManager.default.removeItem(at: file)
        } catch {
            Issue.record("Could not remove the temporary blob file.")
        }
    }

    try await client.uploadBlob(hash: BlobHash(validHash), file: file)

    let sent = try #require(server.requests.first)
    #expect(sent.method == "PUT")
    #expect(sent.path == "/v1/blobs/\(validHash)")
    #expect(sent.contentType == "application/octet-stream")
    #expect(sent.authorization == "Bearer dummy-token")
    #expect(sent.body == Data("hello".utf8))
}

private struct ErrorCase {
    let status: Int
    let code: AdminErrorCode
    let sentence: String

    init(_ status: Int, _ code: AdminErrorCode, _ sentence: String) {
        self.status = status
        self.code = code
        self.sentence = sentence
    }
}

@Test func serverErrorsBecomeReadableSentences() async throws {
    let cases = [
        ErrorCase(401, .unauthorized, "The token is missing or invalid. Run `padctl login <server URL>` again."),
        ErrorCase(403, .forbidden, "The server refused this device. Connect from inside the tailnet."),
        ErrorCase(404, .projectNotFound, "The project was not found on the server."),
        ErrorCase(404, .fileNotFound, "The file was not found on the server."),
        ErrorCase(404, .shareLinkNotFound, "The share link was not found on the server."),
        ErrorCase(
            409, .deploymentIncomplete,
            "The deployment is incomplete: some blobs are missing or the project cannot take this action now."),
        ErrorCase(413, .payloadTooLarge, "The upload is larger than the server accepts."),
        ErrorCase(400, .invalidRequest, "The server rejected the request: bad name"),
        ErrorCase(500, .internalError, "The server failed to handle the request. Try again later."),
    ]
    for errorCase in cases {
        let (status, code, sentence) = (errorCase.status, errorCase.code, errorCase.sentence)
        let body = #"{"error":{"code":"\#(code.rawValue)","message":"bad name"}}"#
        let server = StubServer(.json(status: status, body: body))
        let client = try server.makeClient()

        do {
            _ = try await client.listProjects()
            Issue.record("Expected an error for status \(status).")
        } catch let error as AdminClientError {
            #expect(error.description == sentence)
            #expect(error == .server(status: status, code: code, message: "bad name"))
        }
    }
}

@Test func nonAdminErrorBodyFallsBackToStatusSentence() async throws {
    let server = StubServer(.json(status: 502, body: "<html>Bad Gateway</html>"))
    let client = try server.makeClient()

    do {
        _ = try await client.listProjects()
        Issue.record("Expected an error.")
    } catch let error as AdminClientError {
        #expect(error.description == "The server returned HTTP 502.")
    }
}

@Test func undecodableSuccessBodyIsInvalidResponse() async throws {
    let server = StubServer(.json(status: 200, body: "not json"))
    let client = try server.makeClient()

    await #expect(throws: AdminClientError.invalidResponse) {
        try await client.listProjects()
    }
}

@Test func connectionFailureIsReadableAndDoesNotExposeToken() async throws {
    let server = StubServer(.failure(URLError(.cannotConnectToHost)))
    let client = try server.makeClient(token: "dummy-token")

    do {
        _ = try await client.listProjects()
        Issue.record("Expected an error.")
    } catch let error as AdminClientError {
        #expect(error == .connectionFailed)
        #expect(!error.description.contains("dummy-token"))
    }
}

@Test(arguments: [nil, "", "dummy-token"] as [String?], [true, false])
func clientRequiresSavedConfigAndToken(token: String?, hasConfig: Bool) throws {
    let config = hasConfig ? try PadctlConfig(serverURL: #require(URL(string: "https://pad.example.com"))) : nil
    let configStore = StubServerConfigStore(config: config)
    let tokenStore = StubServerTokenStore(token: token)

    if hasConfig, token == "dummy-token" {
        _ = try AdminClient(configStore: configStore, tokenStore: tokenStore)
    } else {
        #expect(throws: AdminClientError.notLoggedIn) {
            try AdminClient(configStore: configStore, tokenStore: tokenStore)
        }
    }
}

@Test func streamLogsYieldsEntriesAcrossChunkBoundaries() async throws {
    let first = #"{"timestamp":"2026-10-17T12:34:56Z","source":"web","level":"info","message":"Started"}"#
    let second = #"{"timestamp":"2026-10-17T12:34:57Z","source":"web","level":"error","message":"Failed"}"#
    let payload = Data("\(first)\n\(second)\n".utf8)
    let split = payload.count / 2
    let server = StubServer(
        .chunks(status: 200, [payload.prefix(split), payload.dropFirst(split)].map { Data($0) })
    )
    let client = try server.makeClient()

    var entries: [LogEntry] = []
    for try await entry in try await client.streamLogs() {
        entries.append(entry)
    }

    let sent = try #require(server.requests.first)
    #expect(sent.path == "/v1/logs/stream")
    #expect(sent.authorization == "Bearer dummy-token")
    #expect(entries.map(\.message) == ["Started", "Failed"])
    #expect(entries.map(\.level) == [.info, .error])
}

@Test func streamLogsThrowsReadableErrorForNonSuccessStatus() async throws {
    let body = #"{"error":{"code":"unauthorized","message":"Unauthorized."}}"#
    let server = StubServer(.json(status: 401, body: body))
    let client = try server.makeClient()

    await #expect(throws: AdminClientError.server(status: 401, code: .unauthorized, message: "Unauthorized.")) {
        _ = try await client.streamLogs()
    }
}

@Test func streamLogsReportsMalformedLineAsInvalidResponse() async throws {
    let server = StubServer(.chunks(status: 200, [Data("not json\n".utf8)]))
    let client = try server.makeClient()

    await #expect(throws: AdminClientError.invalidResponse) {
        for try await entry in try await client.streamLogs() {
            Issue.record("Unexpected entry: \(entry.message)")
        }
    }
}

private func makeDeploymentRequest() throws -> AdminDeploymentRequest {
    let name = try ProjectName("example-site")
    let route = try Route(
        project: name,
        host: RouteHost("www.example.com"),
        pathPrefix: RoutePathPrefix("/"),
        target: .staticSite
    )
    return try AdminDeploymentRequest(
        manifest: ProjectManifest(name: name, root: "dist", routes: [route]),
        files: [AdminDeploymentFile(path: "index.html", hash: BlobHash(validHash))]
    )
}
