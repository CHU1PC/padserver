import Foundation
import Testing

import PadDomain
@testable import PadInfrastructure

@Test func readsEmptyListWhenFileDoesNotExistAndPersistsProjects() throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let repository = FileProjectRepository(fileURL: directory.appendingPathComponent("projects.json"))

    #expect(try repository.listProjects().isEmpty)

    let projects = [try makeProject("site-one"), try makeProject("site-two")]
    try repository.saveProjects(projects)

    #expect(try repository.listProjects() == projects)

    let replacementProjects = [try makeProject("replacement-site")]
    try repository.saveProjects(replacementProjects)

    #expect(try repository.listProjects() == replacementProjects)
}

@Test func rejectsCorruptJSON() throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let fileURL = directory.appendingPathComponent("projects.json")
    try Data("not json".utf8).write(to: fileURL)
    let repository = FileProjectRepository(fileURL: fileURL)

    #expect(throws: DecodingError.self) {
        try repository.listProjects()
    }
}

@Test func preservesExistingProjectsWhenTemporaryWriteStopsEarly() throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let fileURL = directory.appendingPathComponent("projects.json")
    let originalProjects = [try makeProject("old-site")]
    try FileProjectRepository(fileURL: fileURL).saveProjects(originalProjects)
    let interruptedWrite = FileProjectRepository(
        fileURL: fileURL,
        writeTemporaryFile: { data, temporaryURL in
            try data.prefix(1).write(to: temporaryURL)
            throw TestFailure.interruptedWrite
        },
        renameFile: { _, _ in
            throw TestFailure.renameFailed
        }
    )

    #expect(throws: TestFailure.self) {
        try interruptedWrite.saveProjects([try makeProject("new-site")])
    }
    #expect(try FileProjectRepository(fileURL: fileURL).listProjects() == originalProjects)
}

@Test func preservesExistingProjectsWhenRenameFails() throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let fileURL = directory.appendingPathComponent("projects.json")
    let originalProjects = [try makeProject("old-site")]
    try FileProjectRepository(fileURL: fileURL).saveProjects(originalProjects)
    let failedRename = FileProjectRepository(
        fileURL: fileURL,
        writeTemporaryFile: { data, temporaryURL in
            try data.write(to: temporaryURL)
        },
        renameFile: { _, _ in
            throw TestFailure.renameFailed
        }
    )

    #expect(throws: TestFailure.self) {
        try failedRename.saveProjects([try makeProject("new-site")])
    }
    #expect(try FileProjectRepository(fileURL: fileURL).listProjects() == originalProjects)
}

private enum TestFailure: Error {
    case interruptedWrite
    case renameFailed
}

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        Issue.record("Could not remove test directory: \(error)")
    }
}

private func makeProject(_ name: String) throws -> Project {
    Project(name: try ProjectName(name), kind: .staticSite)
}
