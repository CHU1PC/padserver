import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func getProjectUsageReturnsUsageOfRegisteredProject() async throws {
    let name = try ProjectName("app")
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: name, kind: .compose), routes: [])
    let usage = try ProjectUsage(
        cpuUsage: 1.5, memoryBytes: 2_048, measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
    let getUsage = GetProjectUsage(storage: storage, usageSource: FixedUsageSource(usages: [name: usage]))

    #expect(try await getUsage(of: name) == usage)
}

@Test func getProjectUsageReturnsNilWhenUsageCannotBeMeasured() async throws {
    let name = try ProjectName("blog")
    let storage = InMemoryProjectStorage()
    try await storage.saveProject(Project(name: name, kind: .staticSite), routes: [])
    let getUsage = GetProjectUsage(storage: storage, usageSource: FixedUsageSource(usages: [:]))

    #expect(try await getUsage(of: name) == nil)
}

@Test func getProjectUsageFailsForUnregisteredProjectWithoutAskingUsageSource() async throws {
    let unknown = try ProjectName("unknown")
    let usage = try ProjectUsage(cpuUsage: 0.5, memoryBytes: 1, measuredAt: Date(timeIntervalSince1970: 0))
    let getUsage = GetProjectUsage(
        storage: InMemoryProjectStorage(), usageSource: FixedUsageSource(usages: [unknown: usage]))

    await #expect(throws: GetProjectUsage.Failure.projectNotFound) {
        try await getUsage(of: unknown)
    }
}
