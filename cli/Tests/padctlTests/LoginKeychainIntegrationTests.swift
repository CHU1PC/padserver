import Foundation
import Testing
@testable import padctl

@Test(.enabled(if: ProcessInfo.processInfo.environment["PADCTL_KEYCHAIN_INTEGRATION"] == "1"))
func loginWritesTokenToIsolatedRealKeychainWithoutPuttingItInConfig() throws {
    let identity = KeychainTokenIdentity(service: "padctl.integration.\(UUID().uuidString)", account: "admin-token")
    let tokenStore = KeychainTokenStore(identity: identity)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let configURL = directory.appendingPathComponent("config.json")
    let configStore = ConfigFileStore(fileURL: configURL)
    defer {
        do {
            try tokenStore.save(nil)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        } catch {
            Issue.record("Could not clean up isolated Keychain integration resources: \(error)")
        }
    }
    let service = LoginService(configStore: configStore, tokenStore: tokenStore)
    let serverURL = try #require(URL(string: "https://pad.example.com"))

    try service.login(serverURL: serverURL, token: "dummy-integration-token")

    #expect(try tokenStore.load() == "dummy-integration-token")
    #expect(try configStore.load()?.serverURL == serverURL)
    let contents = try String(contentsOf: configURL, encoding: .utf8)
    #expect(!contents.contains("dummy-integration-token"))
    try service.login(serverURL: serverURL, token: "updated-dummy-token")
    #expect(try tokenStore.load() == "updated-dummy-token")
}
