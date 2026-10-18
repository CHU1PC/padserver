import Foundation
import PadApplication
import PadDomain
import Security

public struct KeychainSecretStore: SecretStore {
    private enum Account {
        static let service = "padserver"
        static let adminToken = "admin-token"
        static let projectPrefix = "project:"
        static let projectSeparator = ":"
    }

    private let client: any KeychainClient

    public init() {
        client = SecurityKeychainClient()
    }

    init(client: any KeychainClient) {
        self.client = client
    }

    public func secret(named name: String, for project: ProjectName) async throws -> String? {
        let account = Self.projectAccount(name: name, project: project)
        guard let data = try await client.read(service: Account.service, account: account) else {
            return nil
        }
        return try Self.decode(data)
    }

    public func setSecret(_ value: String, named name: String, for project: ProjectName) async throws {
        let account = Self.projectAccount(name: name, project: project)
        try await client.write(Data(value.utf8), service: Account.service, account: account)
    }

    public func secretNames(for project: ProjectName) async throws -> [String] {
        let prefix = Self.projectPrefix(for: project)
        let accounts = try await client.accounts(service: Account.service, accountPrefix: prefix)
        return accounts.compactMap { account in
            guard account.hasPrefix(prefix) else {
                return nil
            }
            return String(account.dropFirst(prefix.count))
        }.sorted()
    }

    public func removeSecret(named name: String, for project: ProjectName) async throws {
        let account = Self.projectAccount(name: name, project: project)
        try await client.delete(service: Account.service, account: account)
    }

    public func adminToken() async throws -> AdminToken? {
        guard let data = try await client.read(service: Account.service, account: Account.adminToken) else {
            return nil
        }
        return AdminToken(try Self.decode(data))
    }

    public func setAdminToken(_ token: AdminToken) async throws {
        try await client.write(Data(token.value.utf8), service: Account.service, account: Account.adminToken)
    }

    private static func projectPrefix(for project: ProjectName) -> String {
        Account.projectPrefix + project.value + Account.projectSeparator
    }

    private static func projectAccount(name: String, project: ProjectName) -> String {
        projectPrefix(for: project) + name
    }

    private static func decode(_ data: Data) throws -> String {
        guard let value = String(data: data, encoding: .utf8) else {
            throw KeychainClientError.invalidStoredValue
        }
        return value
    }
}

protocol KeychainClient: Sendable {
    func read(service: String, account: String) async throws -> Data?
    func write(_ data: Data, service: String, account: String) async throws
    func delete(service: String, account: String) async throws
    func accounts(service: String, accountPrefix: String) async throws -> [String]
}

enum KeychainClientError: Error, Equatable {
    case operationFailed(Int32)
    case invalidResponse
    case invalidStoredValue
}

enum KeychainItemAttributes {
    static func add(_ data: Data, service: String, account: String) -> [CFString: CFTypeRef] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecAttrAccount: account as CFString,
        ].merging(update(data)) { _, new in new }
    }

    // 保存済みの項目も、次の保存で読める条件が更新される。
    static func update(_ data: Data) -> [CFString: CFTypeRef] {
        [
            kSecValueData: data as CFData,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
    }
}

private actor SecurityKeychainClient: KeychainClient {
    func read(service: String, account: String) throws -> Data? {
        var query = itemQuery(service: service, account: account)
        query[kSecReturnData] = kCFBooleanTrue
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainClientError.operationFailed(status)
        }
        // Security.framework は結果を CFTypeRef で返すため、この境界で Data に変換する。
        guard let data = result as? Data else {
            throw KeychainClientError.invalidResponse
        }
        return data
    }

    func write(_ data: Data, service: String, account: String) throws {
        let query = itemQuery(service: service, account: account)
        let attributes = KeychainItemAttributes.update(data)
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainClientError.operationFailed(updateStatus)
        }

        let addQuery = KeychainItemAttributes.add(data, service: service, account: account)
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            return
        }
        guard addStatus == errSecDuplicateItem else {
            throw KeychainClientError.operationFailed(addStatus)
        }

        let retryStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard retryStatus == errSecSuccess else {
            throw KeychainClientError.operationFailed(retryStatus)
        }
    }

    func delete(service: String, account: String) throws {
        let status = SecItemDelete(itemQuery(service: service, account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainClientError.operationFailed(status)
        }
    }

    func accounts(service: String, accountPrefix: String) throws -> [String] {
        let query: [CFString: CFTypeRef] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
            kSecReturnAttributes: kCFBooleanTrue,
            kSecMatchLimit: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return []
        }
        guard status == errSecSuccess else {
            throw KeychainClientError.operationFailed(status)
        }
        return try projectAccounts(from: result, accountPrefix: accountPrefix)
    }

    private func projectAccounts(from result: CFTypeRef?, accountPrefix: String) throws -> [String] {
        guard let result, let items = result as? [[CFString: CFTypeRef]] else {
            throw KeychainClientError.invalidResponse
        }
        return try items.compactMap { item in
            guard let account = item[kSecAttrAccount] as? String else {
                throw KeychainClientError.invalidResponse
            }
            return account.hasPrefix(accountPrefix) ? account : nil
        }
    }

    private func itemQuery(service: String, account: String?) -> [CFString: CFTypeRef] {
        var query: [CFString: CFTypeRef] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service as CFString,
        ]
        if let account {
            query[kSecAttrAccount] = account as CFString
        }
        return query
    }
}
