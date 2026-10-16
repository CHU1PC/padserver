import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func listProjectsReturnsEmptyListWhenNoProjectsExist() async throws {
    let list = ListProjects(storage: InMemoryProjectStorage())

    #expect(try await list().isEmpty)
}

@Test func listProjectsReturnsKindActiveReleaseAndRunningStatePerProject() async throws {
    let storage = InMemoryProjectStorage()
    let site = Project(name: try ProjectName("site"), kind: .staticSite)
    let container = Project(name: try ProjectName("container"), kind: .compose)
    let stopped = Project(name: try ProjectName("stopped"), kind: .staticSite)
    for project in [site, container, stopped] {
        try await storage.saveProject(project, routes: [])
    }
    try await storage.saveProjectRunState(.stopped, for: stopped.name)
    let oldID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
    let activeID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002")))
    let preparingID = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000003")))
    for id in [oldID, activeID] {
        try await storage.saveRelease(
            Release(id: id, project: site.name, state: .preparing), manifest: ReleaseManifest(files: []))
        try await storage.activateRelease(id, for: site.name)
    }
    try await storage.saveRelease(
        Release(id: preparingID, project: container.name, state: .preparing), manifest: ReleaseManifest(files: []))

    let result = try await ListProjects(storage: storage)()

    try #require(result.count == 3)
    #expect(result[0].project == site)
    #expect(result[0].activeRelease == Release(id: activeID, project: site.name, state: .active))
    #expect(result[0].running)
    #expect(result[1].project == container)
    #expect(result[1].activeRelease == nil)
    #expect(result[1].running)
    #expect(result[2].project == stopped)
    #expect(result[2].activeRelease == nil)
    #expect(!result[2].running)
}
