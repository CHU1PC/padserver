import Foundation
@testable import PadGuest
import Testing

// Docker Engine API の文書にある応答の例 (ID は文書の見本の値).
private let listJSON = """
    [{"Id":"8dfafdbc3a40","Names":["/boring_feynman"],"Image":"ubuntu:latest",\
    "ImageID":"d74508fb6632491cea586a1fd7d748dfc5274cd6fdfedee309ecf40e8e0e5c88","Command":"echo 1",\
    "Created":1367854155,"State":"Exited","Status":"Exit 0","Ports":[{"PrivatePort":2222,"PublicPort":3333,\
    "Type":"tcp"}],"Labels":{"com.example.vendor":"Acme"},"HostConfig":{"NetworkMode":"default"}},\
    {"Id":"9cd87474be90","Names":["/coolName"],"Image":"ubuntu:latest","Command":"echo 222222",\
    "Created":1367854155,"State":"running","Status":"Up 2 hours","Ports":[],"Labels":{}}]
    """
private let createdJSON = #"{"Id":"e90e34656806","Warnings":[]}"#
private let waitJSON = #"{"StatusCode":137,"Error":null}"#

private let containerID = "e90e34656806"

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

@Test(.timeLimit(.minutes(1)))
func listContainersDecodesDocumentedResponse() async throws {
    try await withServer(routes: ["/containers/json": respond(200, listJSON)]) { client, log in
        let containers = try await client.listContainers()

        #expect(
            containers == [
                ContainerSummary(
                    id: "8dfafdbc3a40", names: ["/boring_feynman"], image: "ubuntu:latest", state: "Exited",
                    status: "Exit 0", labels: ["com.example.vendor": "Acme"]),
                ContainerSummary(
                    id: "9cd87474be90", names: ["/coolName"], image: "ubuntu:latest", state: "running",
                    status: "Up 2 hours"),
            ])
        #expect(await log.requests == [RecordedRequest(method: "GET", path: "/containers/json", body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func listContainersWithAllAddsQuery() async throws {
    try await withServer(routes: ["/containers/json?all=true": respond(200, "[]")]) { client, log in
        let containers = try await client.listContainers(all: true)

        #expect(containers.isEmpty)
        #expect(await log.requests.map(\.path) == ["/containers/json?all=true"])
    }
}

@Test(.timeLimit(.minutes(1)))
func listContainersRejectsMalformedBody() async throws {
    try await withServer(routes: ["/containers/json": respond(200, "not json")]) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) { try await client.listContainers() }
    }
}

@Test(.timeLimit(.minutes(1)))
func listContainersRejectsErrorStatus() async throws {
    try await withServer(routes: ["/containers/json": respond(500)]) { client, _ in
        await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) { try await client.listContainers() }
    }
}

@Test(.timeLimit(.minutes(1)))
func createContainerSendsRequestAndReturnsID() async throws {
    try await withServer(routes: ["/containers/create?name=web": respond(201, createdJSON)]) { client, log in
        let request = CreateContainerRequest(
            image: "nginx:alpine", cmd: ["nginx", "-g", "daemon off;"], env: ["MODE=test"],
            exposedPorts: ["80/tcp"],
            hostConfig: ContainerHostConfig(
                portBindings: ["80/tcp": [ContainerPortBinding(hostIP: "127.0.0.1", hostPort: "8080")]]))

        let id = try await client.createContainer(request, name: "web")

        #expect(id == containerID)
        let expectedBody =
            #"{"Cmd":["nginx","-g","daemon off;"],"Env":["MODE=test"],"ExposedPorts":{"80\/tcp":{}},"#
            + #""HostConfig":{"PortBindings":{"80\/tcp":[{"HostIp":"127.0.0.1","HostPort":"8080"}]}},"#
            + #""Image":"nginx:alpine"}"#
        #expect(
            await log.requests == [
                RecordedRequest(method: "POST", path: "/containers/create?name=web", body: expectedBody)
            ])
    }
}

@Test(.timeLimit(.minutes(1)))
func createContainerWithImageOnlyOmitsOptionalFields() async throws {
    try await withServer(routes: ["/containers/create": respond(201, createdJSON)]) { client, log in
        _ = try await client.createContainer(CreateContainerRequest(image: "alpine"))

        #expect(await log.requests.map(\.body) == [#"{"Image":"alpine"}"#])
    }
}

@Test(.timeLimit(.minutes(1)))
func createContainerMapsMissingImageToNotFound() async throws {
    let missing = respond(404, #"{"message":"No such image: x"}"#)
    try await withServer(routes: ["/containers/create": missing]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.notFound) {
            try await client.createContainer(CreateContainerRequest(image: "x"))
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func createContainerMapsNameConflict() async throws {
    try await withServer(routes: ["/containers/create?name=web": respond(409)]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.conflict) {
            try await client.createContainer(CreateContainerRequest(image: "x"), name: "web")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func createContainerRejectsMalformedBody() async throws {
    try await withServer(routes: ["/containers/create": respond(201, "not json")]) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) {
            try await client.createContainer(CreateContainerRequest(image: "x"))
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [204, 304])
func startContainerSucceedsWhenStartedOrAlreadyRunning(status: Int) async throws {
    try await withServer(routes: ["/containers/\(containerID)/start": respond(status)]) { client, log in
        try await client.startContainer(id: containerID)

        #expect(
            await log.requests == [RecordedRequest(method: "POST", path: "/containers/\(containerID)/start", body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func startContainerMapsMissingContainerToNotFound() async throws {
    try await withServer(routes: ["/containers/\(containerID)/start": respond(404)]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.notFound) { try await client.startContainer(id: containerID) }
    }
}

@Test(.timeLimit(.minutes(1)))
func startContainerRejectsErrorStatus() async throws {
    try await withServer(routes: ["/containers/\(containerID)/start": respond(500)]) { client, _ in
        await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) {
            try await client.startContainer(id: containerID)
        }
    }
}

@Test(.timeLimit(.minutes(1)), arguments: [204, 304])
func stopContainerSucceedsWhenStoppedOrAlreadyStopped(status: Int) async throws {
    try await withServer(routes: ["/containers/\(containerID)/stop": respond(status)]) { client, log in
        try await client.stopContainer(id: containerID)

        #expect(
            await log.requests == [RecordedRequest(method: "POST", path: "/containers/\(containerID)/stop", body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func stopContainerMapsMissingContainerToNotFound() async throws {
    try await withServer(routes: ["/containers/\(containerID)/stop": respond(404)]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.notFound) { try await client.stopContainer(id: containerID) }
    }
}

@Test(.timeLimit(.minutes(1)))
func removeContainerSendsDelete() async throws {
    try await withServer(routes: ["/containers/\(containerID)": respond(204)]) { client, log in
        try await client.removeContainer(id: containerID)

        #expect(await log.requests == [RecordedRequest(method: "DELETE", path: "/containers/\(containerID)", body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func removeContainerMapsMissingContainerToNotFound() async throws {
    try await withServer(routes: ["/containers/\(containerID)": respond(404)]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.notFound) {
            try await client.removeContainer(id: containerID)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func removeContainerMapsRunningContainerToConflict() async throws {
    try await withServer(routes: ["/containers/\(containerID)": respond(409)]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.conflict) {
            try await client.removeContainer(id: containerID)
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func waitContainerReturnsExitCode() async throws {
    try await withServer(routes: ["/containers/\(containerID)/wait": respond(200, waitJSON)]) { client, log in
        let exitCode = try await client.waitContainer(id: containerID)

        #expect(exitCode == 137)
        #expect(
            await log.requests == [RecordedRequest(method: "POST", path: "/containers/\(containerID)/wait", body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func waitContainerMapsMissingContainerToNotFound() async throws {
    try await withServer(routes: ["/containers/\(containerID)/wait": respond(404)]) { client, _ in
        await #expect(throws: DockerClient.ContainerError.notFound) { try await client.waitContainer(id: containerID) }
    }
}

@Test(.timeLimit(.minutes(1)))
func waitContainerRejectsMalformedBody() async throws {
    try await withServer(routes: ["/containers/\(containerID)/wait": respond(200, "not json")]) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) {
            try await client.waitContainer(id: containerID)
        }
    }
}
