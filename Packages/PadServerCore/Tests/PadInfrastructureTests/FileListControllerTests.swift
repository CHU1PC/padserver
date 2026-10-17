import Foundation
import Hummingbird
import HummingbirdTesting
import NIOCore
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import PadTestSupport
import Testing

private struct Fixture {
    let fileStore = InMemoryFileStore()
    let linkStore = InMemoryShareLinkStore()

    func makeApplication() -> Application<RouterResponder<AdminRequestContext>> {
        let router = Router(context: AdminRequestContext.self)
        router.add(middleware: AdminErrorMiddleware())
        FileListController(manageFiles: ManageFiles(fileStore: fileStore, linkStore: linkStore))
            .addRoutes(to: router)
        return Application(responder: router.buildResponder())
    }

    func save(_ name: String, _ text: String) async throws {
        _ = try await fileStore.saveFile(named: name, from: SingleChunk(data: Data(text.utf8)))
    }
}

private struct SingleChunk: HTTPBodyStream {
    let data: Data

    func makeAsyncIterator() -> AsyncStream<Data>.Iterator {
        AsyncStream<Data> { continuation in
            continuation.yield(data)
            continuation.finish()
        }.makeAsyncIterator()
    }
}

private func decode<T: Decodable>(_ type: T.Type, from response: TestResponse) throws -> T {
    try AdminAPIJSON.makeDecoder().decode(type, from: Data(response.body.readableBytesView))
}

@Test func listReturnsStoredFiles() async throws {
    let fixture = Fixture()
    try await fixture.save("b.txt", "bb")
    try await fixture.save("a.txt", "a")

    try await fixture.makeApplication().test(.router) { client in
        let response = try await client.execute(uri: "/v1/files", method: .get)
        #expect(response.status == .ok)
        #expect(
            try decode(AdminFilesResponse.self, from: response).files == [
                StoredFile(name: "a.txt", size: 1), StoredFile(name: "b.txt", size: 2),
            ])
    }
}

@Test func listOfEmptyStoreReturnsEmptyArray() async throws {
    try await Fixture().makeApplication().test(.router) { client in
        let response = try await client.execute(uri: "/v1/files", method: .get)
        #expect(response.status == .ok)
        #expect(try decode(AdminFilesResponse.self, from: response).files.isEmpty)
    }
}

@Test func deleteRemovesFileAndItsShareLinks() async throws {
    let fixture = Fixture()
    try await fixture.save("a.txt", "a")
    try await fixture.save("b.txt", "b")
    let link = ShareLink(id: UUID(), expiresAt: Date(timeIntervalSince1970: 1_800_000_000))
    try await fixture.linkStore.saveLink(StoredShareLink(link: link, fileName: "a.txt", secretHash: "hash"))

    try await fixture.makeApplication().test(.router) { client in
        let response = try await client.execute(uri: "/v1/files/a.txt", method: .delete)
        #expect(response.status == .noContent)
        #expect(response.body.readableBytes == 0)
    }

    #expect(try await fixture.fileStore.listFiles().map(\.name) == ["b.txt"])
    #expect(try await fixture.linkStore.listLinks(forFileNamed: "a.txt").isEmpty)
}

@Test func deleteOfMissingFileReturnsFileNotFound() async throws {
    let fixture = Fixture()
    try await fixture.save("a.txt", "a")

    try await fixture.makeApplication().test(.router) { client in
        let response = try await client.execute(uri: "/v1/files/missing.txt", method: .delete)
        #expect(response.status == .notFound)
        #expect(try decode(AdminErrorResponse.self, from: response).error.code == .fileNotFound)
    }
    #expect(try await fixture.fileStore.listFiles().map(\.name) == ["a.txt"])
}

@Test func deleteOfParentDirectoryNameDoesNotTouchStore() async throws {
    let fixture = Fixture()
    try await fixture.save("a.txt", "a")

    try await fixture.makeApplication().test(.router) { client in
        let response = try await client.execute(uri: "/v1/files/..", method: .delete)
        #expect(response.status == .notFound)
    }
    #expect(try await fixture.fileStore.listFiles().map(\.name) == ["a.txt"])
}
