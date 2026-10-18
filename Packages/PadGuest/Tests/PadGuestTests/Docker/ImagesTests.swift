import Foundation
@testable import PadGuest
import Testing

// Docker Engine API の文書にある応答の例 (ID は文書の見本の値).
private let listJSON = """
    [{"Id":"sha256:e216a057b1cb1efc11f8a268f37ef62083e70b1b38323ba252e25ac88904a7a8","ParentId":"",\
    "RepoTags":["ubuntu:12.04","ubuntu:precise"],\
    "RepoDigests":["ubuntu@sha256:992069aee4016783df6345315302fa59681aae51a8eeb2f889dea59290f21787"],\
    "Created":1474925151,"Size":103579269,"SharedSize":0,"VirtualSize":103579269,"Labels":{},"Containers":2},\
    {"Id":"sha256:3e314f95dcace0f5e4fd37b10862fe8398e3c60ed36600bc0ca5fda78b087175","ParentId":"",\
    "RepoTags":null,"RepoDigests":null,"Created":1429259441,"Size":24,"VirtualSize":24,"Labels":{},"Containers":0}]
    """
private let pullProgress = """
    {"status":"Pulling from library/alpine","id":"latest"}
    {"status":"Pulling fs layer","progressDetail":{},"id":"4abcf2066143"}
    {"status":"Download complete","progressDetail":{},"id":"4abcf2066143"}
    {"status":"Status: Downloaded newer image for alpine:latest"}

    """
private let pullErrorLines = """
    {"status":"Pulling from library/missing","id":"latest"}
    {"errorDetail":{"message":"manifest unknown"},"error":"manifest unknown"}

    """
private let loadProgress = #"{"stream":"Loaded image: example.com/app:1\n"}"# + "\n"
private let loadErrorLines = #"{"errorDetail":{"message":"invalid tar header"},"error":"invalid tar header"}"# + "\n"
private let deleteJSON = #"[{"Untagged":"alpine:latest"},{"Deleted":"sha256:4abcf2066143"}]"#

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
func listImagesDecodesDocumentedResponse() async throws {
    try await withServer(routes: ["/images/json": respond(200, listJSON)]) { client, log in
        let images = try await client.listImages()

        #expect(
            images == [
                ImageSummary(
                    id: "sha256:e216a057b1cb1efc11f8a268f37ef62083e70b1b38323ba252e25ac88904a7a8",
                    repoTags: ["ubuntu:12.04", "ubuntu:precise"], size: 103_579_269),
                ImageSummary(
                    id: "sha256:3e314f95dcace0f5e4fd37b10862fe8398e3c60ed36600bc0ca5fda78b087175", repoTags: [],
                    size: 24),
            ])
        #expect(await log.requests == [RecordedRequest(method: "GET", path: "/images/json", body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func listImagesRejectsMalformedBody() async throws {
    try await withServer(routes: ["/images/json": respond(200, "not json")]) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) { try await client.listImages() }
    }
}

@Test(.timeLimit(.minutes(1)))
func listImagesRejectsErrorStatus() async throws {
    try await withServer(routes: ["/images/json": respond(500)]) { client, _ in
        await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) { try await client.listImages() }
    }
}

@Test(.timeLimit(.minutes(1)))
func pullImageSendsFromImageAndTagAndReadsProgress() async throws {
    let routes = ["/images/create?fromImage=alpine&tag=3.20": respond(200, pullProgress)]
    try await withServer(routes: routes) { client, log in
        try await client.pullImage("alpine", tag: "3.20")

        #expect(
            await log.requests == [
                RecordedRequest(method: "POST", path: "/images/create?fromImage=alpine&tag=3.20", body: "")
            ])
    }
}

@Test(.timeLimit(.minutes(1)))
func pullImageDefaultsTagToLatest() async throws {
    let routes = ["/images/create?fromImage=alpine&tag=latest": respond(200, pullProgress)]
    try await withServer(routes: routes) { client, log in
        try await client.pullImage("alpine")

        #expect(await log.requests.map(\.path) == ["/images/create?fromImage=alpine&tag=latest"])
    }
}

@Test(.timeLimit(.minutes(1)))
func pullImageDetectsErrorInOkResponse() async throws {
    let routes = ["/images/create?fromImage=missing&tag=latest": respond(200, pullErrorLines)]
    try await withServer(routes: routes) { client, _ in
        await #expect(throws: DockerClient.ImageError.operationFailed("manifest unknown")) {
            try await client.pullImage("missing")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func pullImageFallsBackToErrorDetailMessage() async throws {
    let body = #"{"errorDetail":{"message":"denied"}}"# + "\n"
    try await withServer(routes: ["/images/create?fromImage=x&tag=latest": respond(200, body)]) { client, _ in
        await #expect(throws: DockerClient.ImageError.operationFailed("denied")) { try await client.pullImage("x") }
    }
}

@Test(.timeLimit(.minutes(1)))
func pullImageRejectsMalformedProgressLine() async throws {
    try await withServer(routes: ["/images/create?fromImage=x&tag=latest": respond(200, "not json\n")]) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) { try await client.pullImage("x") }
    }
}

@Test(.timeLimit(.minutes(1)))
func pullImageMapsMissingImageToNotFound() async throws {
    let missing = respond(404, #"{"message":"pull access denied"}"#)
    try await withServer(routes: ["/images/create?fromImage=x&tag=latest": missing]) { client, _ in
        await #expect(throws: DockerClient.ImageError.notFound) { try await client.pullImage("x") }
    }
}

@Test(.timeLimit(.minutes(1)))
func loadImageStreamsFileBodyAsIs() async throws {
    let content = String(repeating: "0123456789abcdef", count: 16_384)
    try await withTarFile(content) { tar in
        try await withServer(routes: ["/images/load": respond(200, loadProgress)]) { client, log in
            try await client.loadImage(fromFile: tar)

            let requests = await log.requests
            #expect(requests.map(\.method) == ["POST"])
            #expect(requests.map(\.path) == ["/images/load"])
            #expect(requests.first?.body == content)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func loadImageDetectsErrorInOkResponse() async throws {
    try await withTarFile("broken") { tar in
        try await withServer(routes: ["/images/load": respond(200, loadErrorLines)]) { client, _ in
            await #expect(throws: DockerClient.ImageError.operationFailed("invalid tar header")) {
                try await client.loadImage(fromFile: tar)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func loadImageRejectsErrorStatus() async throws {
    try await withTarFile("x") { tar in
        try await withServer(routes: ["/images/load": respond(500)]) { client, _ in
            await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) {
                try await client.loadImage(fromFile: tar)
            }
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func loadImageFailsWhenFileIsMissing() async throws {
    let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).tar")
    try await withServer(routes: ["/images/load": respond(200, loadProgress)]) { client, log in
        await #expect(throws: DockerClient.ClientError.bodyFileUnreadable) {
            try await client.loadImage(fromFile: missing)
        }
        #expect(await log.requests.isEmpty)
    }
}

@Test(.timeLimit(.minutes(1)))
func removeImageSendsDelete() async throws {
    let routes = ["/images/docker.io/library/alpine:latest": respond(200, deleteJSON)]
    try await withServer(routes: routes) { client, log in
        try await client.removeImage(name: "docker.io/library/alpine:latest")

        #expect(
            await log.requests == [
                RecordedRequest(method: "DELETE", path: "/images/docker.io/library/alpine:latest", body: "")
            ])
    }
}

@Test(.timeLimit(.minutes(1)))
func removeImageMapsMissingImageToNotFound() async throws {
    let missing = respond(404, #"{"message":"No such image: x"}"#)
    try await withServer(routes: ["/images/x": missing]) { client, _ in
        await #expect(throws: DockerClient.ImageError.notFound) { try await client.removeImage(name: "x") }
    }
}

@Test(.timeLimit(.minutes(1)))
func removeImageMapsContainerInUseToConflict() async throws {
    let inUse = respond(409, #"{"message":"conflict: unable to remove repository reference"}"#)
    try await withServer(routes: ["/images/x": inUse]) { client, _ in
        await #expect(throws: DockerClient.ImageError.conflict) { try await client.removeImage(name: "x") }
    }
}
