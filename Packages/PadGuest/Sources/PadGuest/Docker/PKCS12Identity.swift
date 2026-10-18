import CommonCrypto
import Crypto
import Foundation
import Security

/// PEM の証明書と鍵から, keychain を使わずに SecIdentity を作る.
@available(macOS 13, iOS 16, *)
enum PKCS12Identity {
    enum IdentityError: Error, Equatable {
        case invalidCertificate
        case invalidKey
        case importFailed
        case encryptionFailed
    }

    private enum Constants {
        static let password = "padserver"
        static let saltLength = 8
        static let ivLength = 16
        static let aesKeyLength = 32
        static let pbkdf2Iterations = 2_048
        static let sha256Block = 64
        static let macKeyID: UInt8 = 3
        static let pkcs12Version: UInt8 = 3
        static let localKeyByte: UInt8 = 0x5A
        static let localKeyLength = 20
        static let localKeyID = [UInt8](repeating: localKeyByte, count: localKeyLength)
        static let byteMask = 0xFF
        static let byteBits = 8
        static let highBit: UInt8 = 0x80
        static let shortFormLimit = 0x80
        static let oidFirstArcWeight = 40
        static let oidHeadArcs = 2
        static let oidGroupBits = 7
        static let oidGroupMask = 0x7F
        static let oidContinuation = 0x80
    }

    private enum Tag {
        static let integer: UInt8 = 0x02
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectID: UInt8 = 0x06
        static let sequence: UInt8 = 0x30
        static let set: UInt8 = 0x31
        static let explicit0: UInt8 = 0xA0
    }

    private enum OID {
        static let pkcs7Data = "1.2.840.113549.1.7.1"
        static let shroudedKeyBag = "1.2.840.113549.1.12.10.1.2"
        static let certBag = "1.2.840.113549.1.12.10.1.3"
        static let x509Certificate = "1.2.840.113549.1.9.22.1"
        static let localKeyID = "1.2.840.113549.1.9.21"
        static let pbes2 = "1.2.840.113549.1.5.13"
        static let pbkdf2 = "1.2.840.113549.1.5.12"
        static let hmacSHA256 = "1.2.840.113549.2.9"
        static let aes256CBC = "2.16.840.1.101.3.4.1.42"
        static let sha256 = "2.16.840.1.101.3.4.2.1"
    }

    static func certificate(pem: String) throws -> SecCertificate {
        guard let der = derBody(of: pem), let certificate = SecCertificateCreateWithData(nil, Data(der) as CFData)
        else { throw IdentityError.invalidCertificate }
        return certificate
    }

    static func make(certificatePEM: String, keyPEM: String) throws -> SecIdentity {
        guard let certificateDER = derBody(of: certificatePEM) else { throw IdentityError.invalidCertificate }
        let keyDER: [UInt8]
        do {
            keyDER = Array(try P256.Signing.PrivateKey(pemRepresentation: keyPEM).derRepresentation)
        } catch {
            throw IdentityError.invalidKey
        }
        var options: [CFString: CFTypeRef] = [kSecImportExportPassphrase: Constants.password as CFString]
        if #available(macOS 15, *) {
            options[kSecImportToMemoryOnly] = kCFBooleanTrue
        }
        var items: CFArray?
        let status = SecPKCS12Import(
            Data(try pkcs12(certificateDER: certificateDER, keyDER: keyDER)) as CFData, options as CFDictionary,
            &items)
        guard status == errSecSuccess,
            let entry = (items as? [[CFString: CFTypeRef]])?.first,
            let value = entry[kSecImportItemIdentity],
            CFGetTypeID(value) == SecIdentityGetTypeID()
        else { throw IdentityError.importFailed }
        return unsafeDowncast(value, to: SecIdentity.self)
    }

    private static func derBody(of pem: String) -> [UInt8]? {
        let body = pem.split(whereSeparator: \.isNewline).filter { !$0.hasPrefix("-----") }.joined()
        guard !body.isEmpty, let data = Data(base64Encoded: body) else { return nil }
        return Array(data)
    }

    private static func pkcs12(certificateDER: [UInt8], keyDER: [UInt8]) throws -> [UInt8] {
        let keyID = der(Tag.set, der(Tag.octetString, Constants.localKeyID))
        let attributes = der(Tag.set, der(Tag.sequence, oid(OID.localKeyID) + keyID))
        let certificate = der(
            Tag.sequence, oid(OID.x509Certificate) + der(Tag.explicit0, der(Tag.octetString, certificateDER)))
        let certBag = der(
            Tag.sequence, oid(OID.certBag) + der(Tag.explicit0, certificate) + attributes)
        let keyBag = der(
            Tag.sequence, oid(OID.shroudedKeyBag) + der(Tag.explicit0, try shroud(keyDER)) + attributes)
        let authenticatedSafe = der(
            Tag.sequence,
            dataContentInfo(der(Tag.sequence, certBag)) + dataContentInfo(der(Tag.sequence, keyBag)))

        let salt = randomBytes(Constants.saltLength)
        let mac = HMAC<SHA256>.authenticationCode(
            for: authenticatedSafe, using: SymmetricKey(data: macKey(salt: salt)))
        let digestInfo = der(
            Tag.sequence,
            der(Tag.sequence, oid(OID.sha256) + der(Tag.null, [])) + der(Tag.octetString, Array(mac)))
        let macData = der(
            Tag.sequence, digestInfo + der(Tag.octetString, salt) + der(Tag.integer, [1]))
        return der(
            Tag.sequence,
            der(Tag.integer, [Constants.pkcs12Version]) + dataContentInfo(authenticatedSafe) + macData)
    }

    /// PBES2 (PBKDF2-HMAC-SHA256 と AES-256-CBC) で暗号化した PKCS#8. SecPKCS12Import は平文の鍵を identity にしない.
    private static func shroud(_ keyDER: [UInt8]) throws -> [UInt8] {
        let salt = randomBytes(Constants.saltLength)
        let initializationVector = randomBytes(Constants.ivLength)
        var derived = [UInt8](repeating: 0, count: Constants.aesKeyLength)
        let derivation = CCKeyDerivationPBKDF(
            CCPBKDFAlgorithm(kCCPBKDF2), Constants.password, Constants.password.utf8.count, salt, salt.count,
            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(Constants.pbkdf2Iterations), &derived,
            derived.count)
        guard derivation == kCCSuccess else { throw IdentityError.encryptionFailed }

        var encrypted = [UInt8](repeating: 0, count: keyDER.count + kCCBlockSizeAES128)
        var encryptedLength = 0
        let encryption = CCCrypt(
            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
            derived, derived.count, initializationVector, keyDER, keyDER.count, &encrypted, encrypted.count,
            &encryptedLength)
        guard encryption == kCCSuccess else { throw IdentityError.encryptionFailed }

        let prf = der(Tag.sequence, oid(OID.hmacSHA256) + der(Tag.null, []))
        let kdf = der(
            Tag.sequence,
            oid(OID.pbkdf2)
                + der(
                    Tag.sequence,
                    der(Tag.octetString, salt) + der(Tag.integer, integerBytes(Constants.pbkdf2Iterations)) + prf))
        let cipher = der(Tag.sequence, oid(OID.aes256CBC) + der(Tag.octetString, initializationVector))
        let algorithm = der(Tag.sequence, oid(OID.pbes2) + der(Tag.sequence, kdf + cipher))
        return der(Tag.sequence, algorithm + der(Tag.octetString, Array(encrypted.prefix(encryptedLength))))
    }

    private static func dataContentInfo(_ content: [UInt8]) -> [UInt8] {
        der(Tag.sequence, oid(OID.pkcs7Data) + der(Tag.explicit0, der(Tag.octetString, content)))
    }

    /// RFC 7292 付録 B の鍵導出 (SHA-256, 繰り返し 1 回).
    private static func macKey(salt: [UInt8]) -> [UInt8] {
        let password: [UInt8] =
            Constants.password.utf16.flatMap { (unit: UInt16) -> [UInt8] in
                [UInt8(Int(unit) >> Constants.byteBits), UInt8(Int(unit) & Constants.byteMask)]
            } + [0, 0]
        let block = Constants.sha256Block
        func stretched(_ bytes: [UInt8]) -> [UInt8] {
            let length = (bytes.count + block - 1) / block * block
            return (0..<length).map { bytes[$0 % bytes.count] }
        }
        let input = [UInt8](repeating: Constants.macKeyID, count: block) + stretched(salt) + stretched(password)
        return Array(SHA256.hash(data: input))
    }

    private static func randomBytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max) }
    }

    private static func unsignedBytes(_ value: Int) -> [UInt8] {
        var bytes: [UInt8] = []
        var remaining = value
        while remaining > 0 {
            bytes.insert(UInt8(remaining & Constants.byteMask), at: 0)
            remaining >>= Constants.byteBits
        }
        return bytes
    }

    private static func integerBytes(_ value: Int) -> [UInt8] {
        let bytes = unsignedBytes(value)
        guard let first = bytes.first, first >= Constants.highBit else { return bytes }
        return [0] + bytes
    }

    private static func oid(_ dotted: String) -> [UInt8] {
        let arcs = dotted.split(separator: ".").compactMap { Int($0) }
        var encoded: [UInt8] = []
        for arc in [arcs[0] * Constants.oidFirstArcWeight + arcs[1]] + arcs.dropFirst(Constants.oidHeadArcs) {
            var groups = [UInt8(arc & Constants.oidGroupMask)]
            var remaining = arc >> Constants.oidGroupBits
            while remaining > 0 {
                groups.insert(UInt8((remaining & Constants.oidGroupMask) | Constants.oidContinuation), at: 0)
                remaining >>= Constants.oidGroupBits
            }
            encoded += groups
        }
        return der(Tag.objectID, encoded)
    }

    private static func der(_ tag: UInt8, _ content: [UInt8]) -> [UInt8] {
        guard content.count >= Constants.shortFormLimit else { return [tag, UInt8(content.count)] + content }
        let length = unsignedBytes(content.count)
        return [tag, Constants.highBit | UInt8(length.count)] + length + content
    }
}
