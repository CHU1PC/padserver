import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@testable import PadInterface

@Test func presenterReturnsNoRowsForNoProjects() async throws {
    let statuses = try await ListProjects(storage: InMemoryProjectStorage())()

    #expect(ProjectListPresenter.rows(from: statuses).isEmpty)
}

@Test func presenterMapsNameKindStateAndShortReleaseInOrder() async throws {
    let storage = InMemoryProjectStorage()
    let site = Project(name: try ProjectName("site"), kind: .staticSite)
    let app = Project(name: try ProjectName("app"), kind: .compose)
    for project in [site, app] {
        try await storage.saveProject(project, routes: [])
    }
    try await storage.saveProjectRunState(.stopped, for: app.name)
    let releaseID = ReleaseID(try #require(UUID(uuidString: "ABCDEF12-0000-4000-8000-000000000001")))
    try await storage.saveRelease(
        Release(id: releaseID, project: site.name, state: .preparing), manifest: ReleaseManifest(files: []))
    try await storage.activateRelease(releaseID, for: site.name)

    let rows = ProjectListPresenter.rows(from: try await ListProjects(storage: storage)())

    #expect(
        rows == [
            ProjectListRow(name: "site", kind: "Static site", isRunning: true, activeRelease: "abcdef12"),
            ProjectListRow(name: "app", kind: "Compose", isRunning: false, activeRelease: nil),
        ])
}
