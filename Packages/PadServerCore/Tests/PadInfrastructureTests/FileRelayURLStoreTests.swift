import Foundation
@testable import PadInfrastructure
import Testing

@Test func fileRelayURLStoreReadsSavedURLFromAnotherInstance() async throws {
    try await withRelayURLStoreDirectory { directory async throws in
        let url = try #require(URL(string: "wss://relay.example.com/tunnel"))
        try await FileRelayURLStore(directory: directory).setRelayURL(url)

        #expect(try await FileRelayURLStore(directory: directory).relayURL() == url)
    }
}

@Test func fileRelayURLStoreReturnsNilWhenNothingIsSaved() async throws {
    try await withRelayURLStoreDirectory { directory async throws in
        #expect(try await FileRelayURLStore(directory: directory).relayURL() == nil)
    }
}

@Test func fileRelayURLStoreOverwritesPreviousURL() async throws {
    try await withRelayURLStoreDirectory { directory async throws in
        let store = FileRelayURLStore(directory: directory)
        let second = try #require(URL(string: "wss://relay2.example.com"))
        try await store.setRelayURL(#require(URL(string: "wss://relay1.example.com")))
        try await store.setRelayURL(second)

        #expect(try await FileRelayURLStore(directory: directory).relayURL() == second)
    }
}

@Test func fileRelayURLStoreCreatesMissingDirectory() async throws {
    try await withRelayURLStoreDirectory { directory async throws in
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        let url = try #require(URL(string: "wss://relay.example.com"))
        try await FileRelayURLStore(directory: nested).setRelayURL(url)

        #expect(try await FileRelayURLStore(directory: nested).relayURL() == url)
    }
}

private func withRelayURLStoreDirectory(_ operation: (URL) async throws -> Void) async throws {
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
