import Crypto
import Foundation
import SwiftASN1
import X509

public protocol CredentialStore: Sendable {
    func load() async throws -> Data?
    func save(_ data: Data) async throws
}

public struct GuestCredentials: Codable, Equatable, Sendable {
    public let caCertificatePEM: String
    public let serverCertificatePEM: String
    public let serverKeyPEM: String
    public let clientCertificatePEM: String
    public let clientKeyPEM: String
}

@available(macOS 11, iOS 14, *)
public struct GuestCredentialsProvider: Sendable {
    private enum Constants {
        // 端末の鍵は回転しないので、guest の start-dockerd と同じ 10 年にする
        static let validityDays = 3650
        // 端末の時計が少し遅れていても、作った直後の証明書が有効になるようにする
        static let secondsPerDay: TimeInterval = 86_400
        static let backdateSeconds: TimeInterval = secondsPerDay
        static let loopbackFirstOctet: UInt8 = 127
        static let loopbackAddress = ASN1OctetString(contentBytes: [loopbackFirstOctet, 0, 0, 1])
    }

    private struct Issued {
        let certificatePEM: String
        let keyPEM: String
    }

    private let store: any CredentialStore
    private let now: @Sendable () -> Date

    public init(store: any CredentialStore, now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.now = now
    }

    public func credentials() async throws -> GuestCredentials {
        if let data = try await store.load() {
            return try JSONDecoder().decode(GuestCredentials.self, from: data)
        }
        let credentials = try generate()
        try await store.save(JSONEncoder().encode(credentials))
        return credentials
    }

    private func generate() throws -> GuestCredentials {
        let caKey = P256.Signing.PrivateKey()
        let caName = try DistinguishedName { CommonName("padserver-docker-ca") }
        let caCertificate = try certificate(
            subject: caName, issuer: caName, publicKey: caKey.publicKey, issuerKey: caKey,
            extensions: Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(keyCertSign: true))
            })

        let server = try issue(
            commonName: "padserver-docker-server", issuer: caName, issuerKey: caKey,
            extensions: serverExtensions())
        let client = try issue(
            commonName: "padserver-docker-client", issuer: caName, issuerKey: caKey,
            extensions: clientExtensions())

        return GuestCredentials(
            caCertificatePEM: try caCertificate.serializeAsPEM().pemString,
            serverCertificatePEM: server.certificatePEM,
            serverKeyPEM: server.keyPEM,
            clientCertificatePEM: client.certificatePEM,
            clientKeyPEM: client.keyPEM)
    }

    private func serverExtensions() throws -> Certificate.Extensions {
        try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.serverAuth])
            SubjectAlternativeNames([.dnsName("localhost"), .ipAddress(Constants.loopbackAddress)])
        }
    }

    private func clientExtensions() throws -> Certificate.Extensions {
        try Certificate.Extensions {
            Critical(BasicConstraints.notCertificateAuthority)
            Critical(KeyUsage(digitalSignature: true))
            try ExtendedKeyUsage([.clientAuth])
        }
    }

    private func issue(
        commonName: String, issuer: DistinguishedName, issuerKey: P256.Signing.PrivateKey,
        extensions: Certificate.Extensions
    ) throws -> Issued {
        let key = P256.Signing.PrivateKey()
        let subject = try DistinguishedName { CommonName(commonName) }
        let certificate = try certificate(
            subject: subject, issuer: issuer, publicKey: key.publicKey, issuerKey: issuerKey,
            extensions: extensions)
        return Issued(certificatePEM: try certificate.serializeAsPEM().pemString, keyPEM: key.pemRepresentation)
    }

    private func certificate(
        subject: DistinguishedName, issuer: DistinguishedName, publicKey: P256.Signing.PublicKey,
        issuerKey: P256.Signing.PrivateKey, extensions: Certificate.Extensions
    ) throws -> Certificate {
        let start = now().addingTimeInterval(-Constants.backdateSeconds)
        return try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: Certificate.PublicKey(publicKey),
            notValidBefore: start,
            notValidAfter: start.addingTimeInterval(Double(Constants.validityDays) * Constants.secondsPerDay),
            issuer: issuer,
            subject: subject,
            signatureAlgorithm: .ecdsaWithSHA256,
            extensions: extensions,
            issuerPrivateKey: Certificate.PrivateKey(issuerKey))
    }
}
