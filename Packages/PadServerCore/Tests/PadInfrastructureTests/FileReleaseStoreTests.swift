import Foundation
import PadApplication
import PadDomain
@testable import PadInfrastructure
import Testing

@Test func fileReleaseStorePersistsReleaseAndManifestAcrossInstances() async throws {
    try await withReleaseStoreDirectory { directory async throws in
        let store = FileReleaseStore(directory: directory)
        let project = try ProjectName("site")
        let id = ReleaseID(try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000062")))
        let release = Release(id: id, project: project, state: .preparing)
        let file = try ReleaseManifestFile(path: "index.html", blob: fixtureBlobHash("opaque"))
        let manifest = ReleaseManifest(files: [file])

        try await store.saveRelease(release, manifest: manifest)

        let reopened = FileReleaseStore(directory: directory)
        #expect(try await reopened.listReleases() == [release])
        #expect(try await reopened.releaseManifest(for: id) == manifest)
    }
}

@Test func fileReleaseStoreSwitchesOnlyTargetProjectAndPreservesManifests() async throws {
    try await withReleaseStoreDirectory { directory async throws in
        let store = FileReleaseStore(directory: directory)
        let first = try releaseStoreFixture("00000000-0000-0000-0000-000000000003", project: "site")
        let second = try releaseStoreFixture("00000000-0000-0000-0000-000000000001", project: "site")
        let other = try releaseStoreFixture("00000000-0000-0000-0000-000000000002", project: "other")
        let file = try ReleaseManifestFile(path: "index.html", blob: fixtureBlobHash("opaque"))
        let manifest = ReleaseManifest(files: [file])
        for release in [first, second, other] {
            try await store.saveRelease(release, manifest: manifest)
        }
        try await store.activateRelease(first.id, for: first.project)
        try await store.activateRelease(other.id, for: other.project)
        try await store.activateRelease(second.id, for: second.project)

        let reopened = FileReleaseStore(directory: directory)
        #expect(
            try await reopened.listReleases() == [
                Release(id: first.id, project: first.project, state: .retired),
                Release(id: second.id, project: second.project, state: .active),
                Release(id: other.id, project: other.project, state: .active),
            ])
        #expect(try await reopened.releaseManifest(for: first.id) == manifest)
        #expect(try await reopened.releaseManifest(for: second.id) == manifest)
    }
}

@Test func fileReleaseStoreFailedReplacementLeavesOldActiveOnDisk() async throws {
    try await withReleaseStoreDirectory { directory async throws in
        let store = FileReleaseStore(directory: directory)
        let old = try releaseStoreFixture("00000000-0000-0000-0000-000000000001", project: "site")
        let next = try releaseStoreFixture("00000000-0000-0000-0000-000000000002", project: "site")
        let manifest = ReleaseManifest(files: [])
        try await store.saveRelease(old, manifest: manifest)
        try await store.activateRelease(old.id, for: old.project)
        try await store.saveRelease(next, manifest: manifest)
        let fileURL = directory.appendingPathComponent("releases.json")
        let before = try Data(contentsOf: fileURL)
        let failing = FileReleaseStore(
            directory: directory,
            writeData: { _, _ in
                throw ReleaseStoreWriteFailure.denied
            })

        await #expect(throws: ReleaseStoreWriteFailure.self) {
            try await failing.activateRelease(next.id, for: next.project)
        }

        #expect(try Data(contentsOf: fileURL) == before)
        let reopened = FileReleaseStore(directory: directory)
        #expect(
            try await reopened.listReleases() == [
                Release(id: old.id, project: old.project, state: .active), next,
            ])
    }
}

@Test func fileReleaseStoreRejectsInvalidTargetsWithoutChangingState() async throws {
    try await withReleaseStoreDirectory { directory async throws in
        let store = FileReleaseStore(directory: directory)
        let first = try releaseStoreFixture("00000000-0000-0000-0000-000000000001", project: "site")
        let missing = try releaseStoreFixture("00000000-0000-0000-0000-000000000002", project: "site")
        try await store.saveRelease(first, manifest: ReleaseManifest(files: []))
        try await store.activateRelease(first.id, for: first.project)
        let before = try await store.listReleases()
        await #expect(throws: FileReleaseStore.Failure.self) {
            try await store.activateRelease(missing.id, for: missing.project)
        }
        await #expect(throws: FileReleaseStore.Failure.self) {
            try await store.activateRelease(first.id, for: ProjectName("other"))
        }
        await #expect(throws: FileReleaseStore.Failure.self) {
            try await store.activateRelease(first.id, for: first.project)
        }
        #expect(try await store.listReleases() == before)
    }
}

@Test func fileReleaseStoreRejectsDuplicateAndNonPreparingSaves() async throws {
    try await withReleaseStoreDirectory { directory async throws in
        let store = FileReleaseStore(directory: directory)
        let first = try releaseStoreFixture("00000000-0000-0000-0000-000000000001", project: "site")
        let manifest = ReleaseManifest(files: [])
        try await store.saveRelease(first, manifest: manifest)
        await #expect(throws: FileReleaseStore.Failure.self) {
            try await store.saveRelease(first, manifest: manifest)
        }
        let other = try releaseStoreFixture("00000000-0000-0000-0000-000000000002", project: "site")
        for state: ReleaseState in [.active, .retired] {
            await #expect(throws: FileReleaseStore.Failure.self) {
                try await store.saveRelease(
                    Release(id: other.id, project: other.project, state: state), manifest: manifest)
            }
        }
        #expect(try await store.listReleases() == [first])
    }
}

@Test func fileReleaseStoreRemovesManifestAndReleaseTogether() async throws {
    try await withReleaseStoreDirectory { directory async throws in
        let store = FileReleaseStore(directory: directory)
        #expect(try await store.listReleases().isEmpty)
        let first = try releaseStoreFixture("00000000-0000-0000-0000-000000000001", project: "site")
        let other = try releaseStoreFixture("00000000-0000-0000-0000-000000000002", project: "site")
        let manifest = ReleaseManifest(files: [])
        try await store.saveRelease(first, manifest: manifest)
        try await store.saveRelease(other, manifest: manifest)
        try await store.removeRelease(first.id)
        try await store.removeRelease(first.id)
        let reopened = FileReleaseStore(directory: directory)
        #expect(try await reopened.listReleases() == [other])
        await #expect(throws: FileReleaseStore.Failure.self) {
            try await reopened.releaseManifest(for: first.id)
        }
        #expect(try await reopened.releaseManifest(for: other.id) == manifest)
    }
}

private enum ReleaseStoreWriteFailure: Error {
    case denied
}

private func releaseStoreFixture(_ id: String, project: String) throws -> Release {
    Release(id: ReleaseID(try #require(UUID(uuidString: id))), project: try ProjectName(project), state: .preparing)
}

private func withReleaseStoreDirectory(_ operation: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    do {
        try await operation(directory)
    } catch {
        try FileManager.default.removeItem(at: directory)
        throw error
    }
    try FileManager.default.removeItem(at: directory)
}
