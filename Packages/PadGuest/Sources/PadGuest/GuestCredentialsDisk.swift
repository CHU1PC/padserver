import Foundation

public struct GuestCredentialsDisk: Sendable {
    private enum Constants {
        static let blockSize = 512
        static let endOfArchiveSize = 1024
        static let fileMode: UInt16 = 0o600
        static let nameOffset = 0
        static let nameLength = 100
        static let modeOffset = 100
        static let modeLength = 8
        static let sizeOffset = 124
        static let sizeLength = 12
        static let mtimeOffset = 136
        static let mtimeLength = 12
        static let checksumOffset = 148
        static let checksumLength = 8
        static let typeflagOffset = 156
        static let magicOffset = 257
        static let versionOffset = 263
        static let magicLength = 6
        static let versionLength = 2
        static let checksumDigits = 6
        static let octalRadix = 8
    }

    public let url: URL

    public var additionalArguments: [String] {
        [
            "-drive", "file=\(url.path),id=cred,if=none,format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=cred",
        ]
    }

    public static func write(
        _ credentials: GuestCredentials, directory: URL = FileManager.default.temporaryDirectory
    ) throws -> GuestCredentialsDisk {
        let url = directory.appendingPathComponent("padserver-cred-\(UUID().uuidString).tar")
        let created = FileManager.default.createFile(
            atPath: url.path, contents: archive(credentials),
            attributes: [.posixPermissions: Int(Constants.fileMode)])
        guard created else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        return GuestCredentialsDisk(url: url)
    }

    public static func archive(_ credentials: GuestCredentials) -> Data {
        let entries = [
            entry(name: "ca.pem", content: credentials.caCertificatePEM),
            entry(name: "server.pem", content: credentials.serverCertificatePEM),
            entry(name: "server-key.pem", content: credentials.serverKeyPEM),
        ]
        return entries.reduce(Data(), +) + Data(count: Constants.endOfArchiveSize)
    }

    public func remove() throws {
        try FileManager.default.removeItem(at: url)
    }

    private static func entry(name: String, content: String) -> Data {
        let body = Data(content.utf8)
        var header = [UInt8](repeating: 0, count: Constants.blockSize)
        put(name, into: &header, at: Constants.nameOffset, length: Constants.nameLength)
        put(
            octal(UInt64(Constants.fileMode), digits: Constants.modeLength - 1), into: &header,
            at: Constants.modeOffset, length: Constants.modeLength)
        put(
            octal(UInt64(body.count), digits: Constants.sizeLength - 1), into: &header,
            at: Constants.sizeOffset, length: Constants.sizeLength)
        put(
            octal(0, digits: Constants.mtimeLength - 1), into: &header,
            at: Constants.mtimeOffset, length: Constants.mtimeLength)
        header[Constants.typeflagOffset] = UInt8(ascii: "0")
        put("ustar", into: &header, at: Constants.magicOffset, length: Constants.magicLength)
        put("00", into: &header, at: Constants.versionOffset, length: Constants.versionLength)

        // checksum 欄を空白 8 個として全バイトを足し、6 桁の 8 進数 + NUL + 空白で書く
        for index in 0..<Constants.checksumLength {
            header[Constants.checksumOffset + index] = UInt8(ascii: " ")
        }
        let checksum = header.reduce(0) { $0 + UInt64($1) }
        put(
            octal(checksum, digits: Constants.checksumDigits), into: &header,
            at: Constants.checksumOffset, length: Constants.checksumDigits + 1)

        var result = Data(header)
        result.append(body)
        let remainder = body.count % Constants.blockSize
        if remainder != 0 {
            result.append(Data(count: Constants.blockSize - remainder))
        }
        return result
    }

    private static func octal(_ value: UInt64, digits: Int) -> String {
        let text = String(value, radix: Constants.octalRadix)
        return String(repeating: "0", count: max(0, digits - text.count)) + text
    }

    private static func put(_ text: String, into header: inout [UInt8], at offset: Int, length: Int) {
        for (index, byte) in text.utf8.prefix(length).enumerated() {
            header[offset + index] = byte
        }
    }
}
