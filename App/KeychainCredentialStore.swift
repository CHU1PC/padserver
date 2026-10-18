import Foundation
import PadGuest
import Security

/// 端末ごとの Docker の鍵を, Keychain の generic password 1 件として持ちます.
actor KeychainCredentialStore: CredentialStore {
    private enum Account {
        static let service = "padserver"
        static let name = "docker-credentials"
    }

    enum StoreError: Error {
        case operationFailed(OSStatus)
        case invalidResponse
    }

    private nonisolated var query: [CFString: CFTypeRef] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Account.service as CFString,
            kSecAttrAccount: Account.name as CFString,
        ]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData] = kCFBooleanTrue
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw StoreError.operationFailed(status) }
        // Security.framework は結果を CFTypeRef で返すため、この境界で Data に変換する。
        guard let data = result as? Data else { throw StoreError.invalidResponse }
        return data
    }

    func save(_ data: Data) throws {
        var item = query
        item[kSecValueData] = data as CFData
        // 画面が閉じていても guest を起動できるよう、初回の unlock のあとは読めるようにする.
        item[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(item as CFDictionary, nil)
        guard status == errSecSuccess else { throw StoreError.operationFailed(status) }
    }
}
