import ArgumentParser
import Darwin
import Foundation

struct LoginService {
    private let configStore: any ConfigStore
    private let tokenStore: any TokenStore

    init(configStore: any ConfigStore, tokenStore: any TokenStore) {
        self.configStore = configStore
        self.tokenStore = tokenStore
    }

    func login(serverURL: URL, token: String) throws {
        guard !token.isEmpty else {
            throw LoginError.emptyToken
        }
        guard token.utf8.count <= TokenInput.maximumByteCount else {
            throw TokenInputError.tooLong
        }
        let config = try PadctlConfig(serverURL: serverURL)
        let oldConfig = try configStore.load()
        let oldToken = try tokenStore.load()

        do {
            try tokenStore.save(token)
            try configStore.save(config)
        } catch {
            var rollbackFailed = false
            do {
                try configStore.save(oldConfig)
            } catch {
                rollbackFailed = true
            }
            do {
                try tokenStore.save(oldToken)
            } catch {
                rollbackFailed = true
            }
            if rollbackFailed {
                throw LoginError.rollbackFailed
            }
            throw LoginError.persistenceFailed
        }
    }
}

enum LoginError: Error {
    case emptyToken
    case persistenceFailed
    case rollbackFailed
}

enum TokenInputError: Error {
    case tooLong
    case invalidUTF8
}

enum TokenInput {
    // 4 KiB exceeds the expected admin-token size while bounding terminal and Keychain input.
    static let maximumByteCount = 4_096
    // This byte lets the prompt distinguish an over-limit token from an exact-limit token.
    static let overflowDetectionByteCount = 1
    // readpassphrase appends a null terminator after the accepted bytes.
    static let cTerminatorByteCount = 1
    static let promptBufferSize = maximumByteCount + overflowDetectionByteCount + cTerminatorByteCount

    static func decode(_ data: Data) throws -> String {
        guard data.count <= maximumByteCount else {
            throw TokenInputError.tooLong
        }
        guard let token = String(data: data, encoding: .utf8) else {
            throw TokenInputError.invalidUTF8
        }
        return token
    }
}

struct Login: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Save the PadServer connection and access token."
    )

    @Argument(help: "Base URL of the PadServer management API.")
    var serverURL: String

    mutating func run() throws {
        guard let url = URL(string: serverURL) else {
            throw ValidationError("The server URL must be an absolute HTTP or HTTPS URL.")
        }
        do {
            _ = try PadctlConfig(serverURL: url)
        } catch {
            throw ValidationError("The server URL must be an absolute HTTP or HTTPS URL without credentials.")
        }

        let token = try readToken()
        let fileURL = ConfigFileStore.defaultFileURL()
        let service = LoginService(
            configStore: ConfigFileStore(fileURL: fileURL),
            tokenStore: KeychainTokenStore()
        )
        try service.login(serverURL: url, token: token)
        print("Login configuration saved.")
    }

    private func readToken() throws -> String {
        var buffer = [CChar](repeating: 0, count: TokenInput.promptBufferSize)
        let result = buffer.withUnsafeMutableBufferPointer { pointer in
            Darwin.readpassphrase("Token: ", pointer.baseAddress, pointer.count, RPP_ECHO_OFF)
        }
        guard result != nil else {
            throw ValidationError("Could not read the token from the secure prompt.")
        }
        let tokenBytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        do {
            return try TokenInput.decode(Data(tokenBytes))
        } catch TokenInputError.tooLong {
            throw ValidationError(
                "The token exceeds the \(TokenInput.maximumByteCount)-byte input limit."
            )
        } catch {
            throw ValidationError("The token must be valid UTF-8.")
        }
    }
}
