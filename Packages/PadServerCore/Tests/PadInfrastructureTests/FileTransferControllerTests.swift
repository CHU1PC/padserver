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

private func makeApplication(store: any FileStore) -> Application<RouterResponder<AdminRequestContext>> {
    let router = Router(context: AdminRequestContext.self)
    router.add(middleware: AdminErrorMiddleware())
    FileTransferController(storeFile: StoreFile(store: store)).addRoutes(to: router)
    return Application(responder: router.buildResponder())
}

private func errorCode(_ response: TestResponse) throws -> AdminErrorCode {
    try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: Data(response.body.readableBytesView))
        .error.code
}

@Test func uploadStoresFileAndReturnsStoredFile() async throws {
    let store = InMemoryFileStore()
    try await makeApplication(store: store).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/files/report.pdf", method: .put, body: ByteBuffer(string: "hello"))
        #expect(response.status == .created)
        let stored = try AdminAPIJSON.makeDecoder().decode(
            StoredFile.self, from: Data(response.body.readableBytesView))
        #expect(stored == StoredFile(name: "report.pdf", size: 5))
    }
    #expect(try await store.file(named: "report.pdf") == StoredFile(name: "report.pdf", size: 5))
}

@Test func downloadReturnsUploadedBytes() async throws {
    let store = InMemoryFileStore()
    try await makeApplication(store: store).test(.router) { client in
        _ = try await client.execute(uri: "/v1/files/a.txt", method: .put, body: ByteBuffer(string: "hello"))
        let response = try await client.execute(uri: "/v1/files/a.txt", method: .get)
        #expect(response.status == .ok)
        #expect(response.headers[.contentType] == "application/octet-stream")
        #expect(String(buffer: response.body) == "hello")
    }
}

@Test func multiChunkRoundTripOverLiveServerIsIntact() async throws {
    let data = Data((0..<(4 << 20)).map { UInt8($0 % 251) })
    try await makeApplication(store: InMemoryFileStore()).test(.live) { client in
        let put = try await client.execute(uri: "/v1/files/big.bin", method: .put, body: ByteBuffer(bytes: data))
        #expect(put.status == .created)
        let response = try await client.execute(uri: "/v1/files/big.bin", method: .get)
        #expect(response.status == .ok)
        #expect(Data(response.body.readableBytesView) == data)
    }
}

@Test func percentEncodedNameIsDecodedBeforeStoring() async throws {
    let store = InMemoryFileStore()
    try await makeApplication(store: store).test(.router) { client in
        let response = try await client.execute(
            uri: "/v1/files/my%20file.txt", method: .put, body: ByteBuffer(string: "x"))
        #expect(response.status == .created)
    }
    #expect(try await store.file(named: "my file.txt") != nil)
}

@Test func downloadOfMissingFileIsNotFound() async throws {
    try await makeApplication(store: InMemoryFileStore()).test(.router) { client in
        let response = try await client.execute(uri: "/v1/files/missing.txt", method: .get)
        #expect(response.status == .notFound)
        #expect(try errorCode(response) == .fileNotFound)
    }
}

@Test func uploadReplacesFileWithSameName() async throws {
    let store = InMemoryFileStore()
    try await makeApplication(store: store).test(.router) { client in
        _ = try await client.execute(uri: "/v1/files/a.txt", method: .put, body: ByteBuffer(string: "first"))
        _ = try await client.execute(uri: "/v1/files/a.txt", method: .put, body: ByteBuffer(string: "2nd"))
        let response = try await client.execute(uri: "/v1/files/a.txt", method: .get)
        #expect(String(buffer: response.body) == "2nd")
    }
}

@Test(arguments: ["..", "%2E%2E", "a%2Fb", "..%2Fsecret", "a%00b"])
func namesEscapingTheStoreAreBadRequest(name: String) async throws {
    let store = InMemoryFileStore()
    try await makeApplication(store: store).test(.router) { client in
        let put = try await client.execute(uri: "/v1/files/\(name)", method: .put, body: ByteBuffer(string: "x"))
        #expect(put.status == .badRequest)
        let get = try await client.execute(uri: "/v1/files/\(name)", method: .get)
        #expect(get.status == .badRequest)
        #expect(try errorCode(get) == .invalidRequest)
    }
    #expect(try await store.listFiles().isEmpty)
}
