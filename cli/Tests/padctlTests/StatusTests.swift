import Foundation
import PadInterface
import Testing
@testable import padctl

private let sampleProjects = """
    {"projects":[
    {"project":{"name":"example-site","kind":"staticSite"},
     "activeRelease":{"id":"00000000-0000-4000-8000-000000000001","project":"example-site","state":"active"},
     "running":true},
    {"project":{"name":"api","kind":"compose"},"activeRelease":null,"running":false}
    ]}
    """

@Test func statusCommandIsRegistered() throws {
    #expect(try Padctl.parseAsRoot(["status"]) is StatusCommand)
}

@Test func statusRendersEachProjectWithKindStateAndRelease() async throws {
    let server = StubServer(.json(status: 200, body: sampleProjects))
    let response = try await server.makeClient().listProjects()

    let lines = StatusReport.render(response).split(separator: "\n").map(String.init)

    #expect(lines.count == 3)
    #expect(lines[0].split(separator: " ").map(String.init) == ["PROJECT", "KIND", "STATE", "RELEASE"])
    #expect(
        lines[1].split(separator: " ").map(String.init)
            == ["example-site", "staticSite", "running", "00000000-0000-4000-8000-000000000001", "(active)"])
    #expect(lines[2].split(separator: " ").map(String.init) == ["api", "compose", "stopped", "-"])
}

@Test func statusRendersMessageWhenThereAreNoProjects() {
    #expect(StatusReport.render(AdminProjectsResponse(projects: [])) == "No projects.")
}
