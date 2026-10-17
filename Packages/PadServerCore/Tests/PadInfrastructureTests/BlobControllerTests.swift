import CryptoKit
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

private func makeApplication(
    storage: any ProjectStorage, maximumBytes: Int64 = BlobController.defaultMaximumBytes
) -> Application<RouterResponder<AdminRequestContext>> {
    let router = Router(context: AdminRequestContext.self)
    router.add(middleware: AdminErrorMiddleware())
    BlobController(storage: storage, maximumBytes: maximumBytes).addRoutes(to: router)
    return Application(responder: router.buildResponder())
}

private func hashString(of data: Data) -> String {
    CryptoKit.SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private func errorCode(_ response: TestResponse) throws -> AdminErrorCode {
    try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: Data(response.body.readableBytesView))
        .error.code
}

private func withStorage(_ body: (FileProjectStorage) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove test directory: \(error)")
        }
    }
    try await body(FileProjectStorage(directory: directory))
}

@Test func uploadStoresBlobAndReturnsCreated() async throws {
    try await withStorage { storage in
        let data = Data("hello".utf8)
        let hash = try BlobHash(hashString(of: data))

        try await makeApplication(storage: storage).test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(response.status == .created)
        }

        #expect(try await storage.blobSize(hash) == Int64(data.count))
    }
}

@Test func uploadStoresMultiChunkBodyIntact() async throws {
    try await withStorage { storage in
        let data = Data(repeating: 0x61, count: 4 << 20)
        let hash = try BlobHash(hashString(of: data))

        try await makeApplication(storage: storage).test(.live) { client in
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(response.status == .created)
        }

        #expect(try await storage.blobSize(hash) == Int64(data.count))
    }
}

@Test func uploadOfExistingBlobReturnsNoContent() async throws {
    try await withStorage { storage in
        let data = Data("hello".utf8)
        let hash = try BlobHash(hashString(of: data))
        try await makeApplication(storage: storage).test(.router) { client in
            let first = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(first.status == .created)
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(response.status == .noContent)
        }
    }
}

@Test func uploadWithMismatchedBodyIsRejectedAndRetryable() async throws {
    try await withStorage { storage in
        let data = Data("hello".utf8)
        let hash = try BlobHash(hashString(of: data))

        try await makeApplication(storage: storage).test(.router) { client in
            let wrong = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(string: "other"))
            #expect(wrong.status == .badRequest)
            #expect(try errorCode(wrong) == .invalidRequest)
            #expect(try await storage.blobExists(hash) == false)

            let retry = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(retry.status == .created)
        }
    }
}

@Test func uploadWithInvalidHashIsBadRequest() async throws {
    let storage = InMemoryProjectStorage()
    try await makeApplication(storage: storage).test(.router) { client in
        for hash in ["abc", String(repeating: "A", count: 64), String(repeating: "g", count: 64)] {
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash)", method: .put, body: ByteBuffer(string: "x"))
            #expect(response.status == .badRequest)
            #expect(try errorCode(response) == .invalidRequest)
        }
    }
}

@Test func uploadOverLimitIsRejectedWithoutStoring() async throws {
    try await withStorage { storage in
        let data = Data(repeating: 0x61, count: 64)
        let hash = try BlobHash(hashString(of: data))

        try await makeApplication(storage: storage, maximumBytes: 32).test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(response.status == .contentTooLarge)
            #expect(try errorCode(response) == .payloadTooLarge)
        }

        #expect(try await storage.blobExists(hash) == false)
    }
}

@Test func uploadOverLimitWithoutContentLengthIsRejectedWhileStreaming() async throws {
    try await withStorage { storage in
        let data = Data(repeating: 0x61, count: 64)
        let hash = try BlobHash(hashString(of: data))

        try await makeApplication(storage: storage, maximumBytes: 32).test(.live) { client in
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, headers: [.transferEncoding: "chunked"],
                body: ByteBuffer(bytes: data))
            #expect(response.status == .contentTooLarge)
        }

        #expect(try await storage.blobExists(hash) == false)
    }
}

@Test func uploadAtLimitIsAccepted() async throws {
    try await withStorage { storage in
        let data = Data(repeating: 0x61, count: 32)
        let hash = try BlobHash(hashString(of: data))

        try await makeApplication(storage: storage, maximumBytes: 32).test(.router) { client in
            let response = try await client.execute(
                uri: "/v1/blobs/\(hash.value)", method: .put, body: ByteBuffer(bytes: data))
            #expect(response.status == .created)
        }
    }
}
