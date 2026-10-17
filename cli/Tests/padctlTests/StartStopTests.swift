import ArgumentParser
import Foundation
import Testing
@testable import padctl

private let exampleProject = #"{"name":"example-site","kind":"staticSite"}"#

private func statusBody(running: Bool) -> String {
    #"{"project":\#(exampleProject),"activeRelease":null,"running":\#(running)}"#
}

@Test func startAndStopCommandsAreRegistered() throws {
    let start = try #require(try Padctl.parseAsRoot(["start", "example-site"]) as? Start)
    let stop = try #require(try Padctl.parseAsRoot(["stop", "example-site"]) as? Stop)
    #expect(start.project == "example-site")
    #expect(stop.project == "example-site")
}

@Test func startCommandRequiresProjectName() {
    #expect(throws: (any Error).self) { try Padctl.parseAsRoot(["start"]) }
    #expect(throws: (any Error).self) { try Padctl.parseAsRoot(["stop"]) }
}

@Test func startPostsToStartPathAndReportsRunning() async throws {
    let server = StubServer(.json(status: 200, body: statusBody(running: true)))
    let service = try ProjectLifecycleService(client: server.makeClient())

    let message = try await service.start(projectName: "example-site")

    #expect(server.requests.map(\.method) == ["POST"])
    #expect(server.requests.map(\.path) == ["/v1/projects/example-site/start"])
    #expect(message == "Project example-site is running.")
}

@Test func stopPostsToStopPathAndReportsStopped() async throws {
    let server = StubServer(.json(status: 200, body: statusBody(running: false)))
    let service = try ProjectLifecycleService(client: server.makeClient())

    let message = try await service.stop(projectName: "example-site")

    #expect(server.requests.map(\.path) == ["/v1/projects/example-site/stop"])
    #expect(message == "Project example-site is stopped.")
}

@Test func invalidProjectNameIsRejectedWithoutRequest() async throws {
    let server = StubServer(.json(status: 200, body: statusBody(running: true)))
    let service = try ProjectLifecycleService(client: server.makeClient())

    await #expect(throws: ValidationError.self) { try await service.start(projectName: "../escape") }
    await #expect(throws: ValidationError.self) { try await service.stop(projectName: "") }
    #expect(server.requests.isEmpty)
}
