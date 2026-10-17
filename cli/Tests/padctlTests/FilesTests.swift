import ArgumentParser
import Foundation
import Testing
@testable import padctl

private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "padctl-files-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func removeTemporaryDirectory(_ directory: URL) {
    do {
        try FileManager.default.removeItem(at: directory)
    } catch {
        Issue.record("Could not remove the temporary files test directory.")
    }
}

@Test func filesCommandsAreRegistered() throws {
    let put = try #require(try Padctl.parseAsRoot(["files", "put", "a.pdf", "--name", "b.pdf"]) as? FilesPut)
    #expect(put.path == "a.pdf")
    #expect(put.name == "b.pdf")
    let get = try #require(try Padctl.parseAsRoot(["files", "get", "b.pdf", "--output", "out"]) as? FilesGet)
    #expect(get.name == "b.pdf")
    #expect(get.output == "out")
    #expect(try Padctl.parseAsRoot(["files", "ls"]) is FilesList)
    let remove = try #require(try Padctl.parseAsRoot(["files", "rm", "b.pdf"]) as? FilesRemove)
    #expect(remove.name == "b.pdf")
}

@Test func putUploadsFileBodyUnderLocalName() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let source = directory.appending(path: "report.pdf")
    try Data("hello".utf8).write(to: source)
    let server = StubServer(.json(status: 201, body: #"{"name":"report.pdf","size":5}"#))
    let service = try FileStoreService(client: server.makeClient())

    let message = try await service.put(path: source.path(), name: nil)

    #expect(server.requests.map(\.method) == ["PUT"])
    #expect(server.requests.map(\.path) == ["/v1/files/report.pdf"])
    #expect(server.requests.map(\.contentType) == ["application/octet-stream"])
    #expect(server.requests[0].authorization == "Bearer dummy-token")
    #expect(server.requests[0].body == Data("hello".utf8))
    #expect(message == "Uploaded report.pdf (5 bytes).")
}

@Test func putPercentEncodesTheName() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let source = directory.appending(path: "local")
    try Data("x".utf8).write(to: source)
    let server = StubServer(.json(status: 201, body: #"{"name":"a b%/c","size":1}"#))
    let service = try FileStoreService(client: server.makeClient())

    _ = try await service.put(path: source.path(), name: "a b%/c")

    #expect(server.requests.map(\.path) == ["/v1/files/a%20b%25%2Fc"])
}

@Test func putRejectsMissingFileAndDirectoryWithoutRequest() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let server = StubServer(.json(status: 201, body: "{}"))
    let service = try FileStoreService(client: server.makeClient())

    await #expect(throws: ValidationError.self) {
        try await service.put(path: directory.appending(path: "missing").path(), name: nil)
    }
    await #expect(throws: ValidationError.self) { try await service.put(path: directory.path(), name: nil) }
    #expect(server.requests.isEmpty)
}

@Test func putReportsInvalidName() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let source = directory.appending(path: "local")
    try Data("x".utf8).write(to: source)
    let server = StubServer(
        .json(status: 400, body: #"{"error":{"code":"invalid_request","message":"File name is invalid."}}"#))
    let service = try FileStoreService(client: server.makeClient())

    await #expect(
        throws: AdminClientError.server(status: 400, code: .invalidRequest, message: "File name is invalid.")
    ) {
        try await service.put(path: source.path(), name: "..")
    }
}

@Test func getSavesBodyToOutputPath() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let output = directory.appending(path: "saved.pdf")
    let server = StubServer(.chunks(status: 200, [Data("hello, ".utf8), Data("world".utf8)]))
    let service = try FileStoreService(client: server.makeClient())

    let message = try await service.get(name: "report.pdf", output: output.path())

    #expect(server.requests.map(\.method) == ["GET"])
    #expect(server.requests.map(\.path) == ["/v1/files/report.pdf"])
    #expect(try Data(contentsOf: output) == Data("hello, world".utf8))
    #expect(message == "Saved report.pdf to \(output.path()).")
}

@Test func getReportsMissingFileAndLeavesNoOutput() async throws {
    let directory = try makeTemporaryDirectory()
    defer { removeTemporaryDirectory(directory) }
    let output = directory.appending(path: "saved.pdf")
    let server = StubServer(
        .json(status: 404, body: #"{"error":{"code":"file_not_found","message":"File was not found."}}"#))
    let service = try FileStoreService(client: server.makeClient())

    await #expect(throws: AdminClientError.server(status: 404, code: .fileNotFound, message: "File was not found.")) {
        try await service.get(name: "missing.pdf", output: output.path())
    }
    #expect(!FileManager.default.fileExists(atPath: output.path()))
}

@Test func listRendersFilesAsTable() async throws {
    let server = StubServer(
        .json(status: 200, body: #"{"files":[{"name":"report.pdf","size":1234},{"name":"a.txt","size":5}]}"#))
    let service = try FileStoreService(client: server.makeClient())

    let message = try await service.list()

    #expect(server.requests.map(\.method) == ["GET"])
    #expect(server.requests.map(\.path) == ["/v1/files"])
    #expect(message == "NAME        SIZE\nreport.pdf  1234\na.txt       5")
}

@Test func listRendersMessageWhenThereAreNoFiles() async throws {
    let server = StubServer(.json(status: 200, body: #"{"files":[]}"#))
    let service = try FileStoreService(client: server.makeClient())

    #expect(try await service.list() == "No files.")
}

@Test func removeSendsDeleteAndReportsRemoved() async throws {
    let server = StubServer(.json(status: 204, body: ""))
    let service = try FileStoreService(client: server.makeClient())

    let message = try await service.remove(name: "report.pdf")

    #expect(server.requests.map(\.method) == ["DELETE"])
    #expect(server.requests.map(\.path) == ["/v1/files/report.pdf"])
    #expect(message == "Removed report.pdf.")
}

@Test func removeReportsMissingFile() async throws {
    let server = StubServer(
        .json(status: 404, body: #"{"error":{"code":"file_not_found","message":"File was not found."}}"#))
    let service = try FileStoreService(client: server.makeClient())

    await #expect(throws: AdminClientError.server(status: 404, code: .fileNotFound, message: "File was not found.")) {
        try await service.remove(name: "missing.pdf")
    }
}
