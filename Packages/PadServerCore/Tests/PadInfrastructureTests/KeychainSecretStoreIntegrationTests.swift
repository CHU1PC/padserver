import Foundation
import PadDomain
import PadInfrastructure
import Testing

@Suite(.enabled(if: ProcessInfo.processInfo.environment["PADSERVER_KEYCHAIN_INTEGRATION"] == "1"))
struct KeychainSecretStoreIntegrationTests {
    @Test func storesReadsUpdatesListsAndDeletesInRealKeychain() async throws {
        let store = KeychainSecretStore()
        // 実 Keychain の既存項目と衝突しないよう、結合試験だけは一意な project 名を使います。
        let project = try ProjectName("test-" + UUID().uuidString.lowercased())
        let name = "fixture"

        do {
            try await store.setSecret("first-fixture", named: name, for: project)
            #expect(try await store.secret(named: name, for: project) == "first-fixture")
            try await store.setSecret("updated-fixture", named: name, for: project)
            #expect(try await store.secret(named: name, for: project) == "updated-fixture")
            #expect(try await store.secretNames(for: project) == [name])
        } catch {
            // 保存後の失敗でも、この試験が作った項目だけを削除します。
            try await store.removeSecret(named: name, for: project)
            throw error
        }

        try await store.removeSecret(named: name, for: project)
        #expect(try await store.secret(named: name, for: project) == nil)
    }
}
