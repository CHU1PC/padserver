import Foundation
import Testing

@testable import PadDomain

@Test func releaseKeepsProjectIDAndState() throws {
    let id = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
    let project = try ProjectName("my-site")
    let release = Release(id: id, project: project, state: .preparing)

    #expect(release.id == id)
    #expect(release.project == project)
    #expect(release.state == .preparing)
}

@Test(arguments: [ReleaseState.preparing, .active, .retired])
func releaseStateRoundTripsThroughJSON(state: ReleaseState) throws {
    let data = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(ReleaseState.self, from: data) == state)
}

@Test func releaseIDUsesSingleJSONValue() throws {
    let id = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
    let data = try JSONEncoder().encode(id)

    #expect(data == Data("\"00000000-0000-0000-0000-000000000001\"".utf8))
    #expect(try JSONDecoder().decode(ReleaseID.self, from: data) == id)
}

@Test func releaseRoundTripsThroughJSON() throws {
    let id = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001")))
    let release = Release(id: id, project: try ProjectName("my-site"), state: .active)
    let data = try JSONEncoder().encode(release)

    #expect(try JSONDecoder().decode(Release.self, from: data) == release)
}
