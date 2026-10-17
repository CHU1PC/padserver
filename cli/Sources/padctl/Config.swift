import Foundation
import Security

struct PadctlConfig: Codable, Equatable {
    let serverURL: URL
    let deviceID: String?

    init(serverURL: URL, deviceID: String? = nil) throws {
        guard Self.isValidServerURL(serverURL) else {
            throw ConfigError.invalidServerURL
        }
        self.serverURL = serverURL
        self.deviceID = deviceID
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let serverURL = try container.decode(URL.self, forKey: .serverURL)
        guard Self.isValidServerURL(serverURL) else {
            throw DecodingError.dataCorruptedError(
                forKey: .serverURL,
                in: container,
                debugDescription: "The server URL is invalid."
            )
        }
        self.serverURL = serverURL
        deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID)
    }

    private enum CodingKeys: String, CodingKey {
        case serverURL
        case deviceID
    }

    private static func isValidServerURL(_ url: URL) -> Bool {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
            let scheme = components.scheme?.lowercased(),
            ["http", "https"].contains(scheme),
            let host = components.host,
            !host.isEmpty,
            components.user == nil,
            components.password == nil
        else {
            return false
        }
        return true
    }
}

enum ConfigError: Error {
    case invalidServerURL
}

protocol ConfigStore {
    func load() throws -> PadctlConfig?
    func save(_ config: PadctlConfig?) throws
}

struct ConfigFileStore: ConfigStore {
    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
    }

    static func defaultFileURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appending(path: ".config", directoryHint: .isDirectory)
            .appending(path: "padctl", directoryHint: .isDirectory)
            .appending(path: "config.json")
    }

    func load() throws -> PadctlConfig? {
        guard fileManager.fileExists(atPath: fileURL.path()) else {
            return nil
        }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode(PadctlConfig.self, from: data)
    }

    func save(_ config: PadctlConfig?) throws {
        guard let config else {
            if fileManager.fileExists(atPath: fileURL.path()) {
                try fileManager.removeItem(at: fileURL)
            }
            return
        }

        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try JSONEncoder().encode(config)
        try data.write(to: fileURL, options: .atomic)
    }
}

protocol TokenStore {
    func load() throws -> String?
    func save(_ token: String?) throws
}

struct KeychainTokenIdentity {
    static let `default` = KeychainTokenIdentity(service: "padctl", account: "admin-token")

    let service: String
    let account: String

    var query: [String: NSObject] {
        [
            kSecClass as String: kSecClassGenericPassword as NSString,
            kSecAttrService as String: service as NSString,
            kSecAttrAccount as String: account as NSString,
        ]
    }
}

struct KeychainTokenStore: TokenStore {
    private let identity: KeychainTokenIdentity

    init(identity: KeychainTokenIdentity = .default) {
        self.identity = identity
    }

    func load() throws -> String? {
        var query = identity.query
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne as NSString
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            throw KeychainTokenStoreError.operationFailed(status)
        }
        return token
    }

    func save(_ token: String?) throws {
        guard let token else {
            let status = SecItemDelete(identity.query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                throw KeychainTokenStoreError.operationFailed(status)
            }
            return
        }

        let attributes = [kSecValueData as String: Data(token.utf8) as NSData]
        let status = SecItemAdd(
            identity.query.merging(attributes) { _, newValue in newValue } as CFDictionary,
            nil
        )
        guard status == errSecDuplicateItem else {
            guard status == errSecSuccess else {
                throw KeychainTokenStoreError.operationFailed(status)
            }
            return
        }

        let updateStatus = SecItemUpdate(identity.query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecSuccess else {
            throw KeychainTokenStoreError.operationFailed(updateStatus)
        }
    }
}

enum KeychainTokenStoreError: Error {
    case operationFailed(OSStatus)
}
