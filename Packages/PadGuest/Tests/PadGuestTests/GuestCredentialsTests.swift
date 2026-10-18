import Crypto
import Foundation
import PadGuest
import Testing
import X509

private actor FakeCredentialStore: CredentialStore {
    private var stored: Data?
    private let failsOnSave: Bool
    private(set) var saveCount = 0

    init(stored: Data? = nil, failsOnSave: Bool = false) {
        self.stored = stored
        self.failsOnSave = failsOnSave
    }

    func load() -> Data? {
        stored
    }

    func save(_ data: Data) throws {
        saveCount += 1
        if failsOnSave {
            throw FakeStoreError.saveFailed
        }
        stored = data
    }
}

private enum FakeStoreError: Error {
    case saveFailed
}

private let fixedReferenceSeconds: TimeInterval = 800_000_000
private let fixedNow = Date(timeIntervalSinceReferenceDate: fixedReferenceSeconds)

private func makeProvider(store: FakeCredentialStore) -> GuestCredentialsProvider {
    GuestCredentialsProvider(store: store, now: { fixedNow })
}

@Test func emptyStoreGeneratesAndSavesCredentials() async throws {
    let store = FakeCredentialStore()

    let credentials = try await makeProvider(store: store).credentials()

    #expect(await store.saveCount == 1)
    #expect(await store.load() != nil)
    #expect(!credentials.serverKeyPEM.isEmpty)
}

@Test func secondCallReturnsSameCredentialsWithoutSaving() async throws {
    let store = FakeCredentialStore()
    let first = try await makeProvider(store: store).credentials()

    let second = try await makeProvider(store: store).credentials()

    #expect(first == second)
    #expect(await store.saveCount == 1)
}

@Test func saveFailureIsThrown() async {
    let store = FakeCredentialStore(failsOnSave: true)

    await #expect(throws: FakeStoreError.self) {
        try await makeProvider(store: store).credentials()
    }
}

@Test func corruptStoredValueIsThrownAndNotOverwritten() async {
    let store = FakeCredentialStore(stored: Data("not json".utf8))

    await #expect(throws: (any Error).self) {
        try await makeProvider(store: store).credentials()
    }
    #expect(await store.saveCount == 0)
}

@Test func certificatesHaveExpectedShape() async throws {
    let store = FakeCredentialStore()
    let credentials = try await makeProvider(store: store).credentials()

    let caCertificate = try Certificate(pemEncoded: credentials.caCertificatePEM)
    let server = try Certificate(pemEncoded: credentials.serverCertificatePEM)
    let client = try Certificate(pemEncoded: credentials.clientCertificatePEM)

    #expect(server.issuer == caCertificate.subject)
    #expect(client.issuer == caCertificate.subject)
    #expect(caCertificate.publicKey.isValidSignature(server.signature, for: server))
    #expect(caCertificate.publicKey.isValidSignature(client.signature, for: client))
    let serverUsage = try server.extensions.extendedKeyUsage
    let clientUsage = try client.extensions.extendedKeyUsage
    #expect(serverUsage?.contains(ExtendedKeyUsage.Usage.serverAuth) == true)
    #expect(clientUsage?.contains(ExtendedKeyUsage.Usage.clientAuth) == true)
    let names = try #require(try server.extensions.subjectAlternativeNames)
    #expect(names.contains(GeneralName.dnsName("localhost")))
    #expect(
        names.contains {
            if case .ipAddress = $0 { true } else { false }
        })
    let caConstraints = try caCertificate.extensions.basicConstraints
    let serverConstraints = try server.extensions.basicConstraints
    #expect(caConstraints == BasicConstraints.isCertificateAuthority(maxPathLength: 0))
    #expect(serverConstraints == BasicConstraints.notCertificateAuthority)
    #expect(server.notValidBefore <= fixedNow)
    #expect(server.notValidAfter > fixedNow)
}

@Test func privateKeysArePKCS8PEMAndDiffer() async throws {
    let store = FakeCredentialStore()
    let credentials = try await makeProvider(store: store).credentials()

    _ = try P256.Signing.PrivateKey(pemRepresentation: credentials.serverKeyPEM)
    _ = try P256.Signing.PrivateKey(pemRepresentation: credentials.clientKeyPEM)
    #expect(credentials.serverKeyPEM != credentials.clientKeyPEM)
}

@Test func differentDevicesGetDifferentCredentials() async throws {
    let first = try await makeProvider(store: FakeCredentialStore()).credentials()
    let second = try await makeProvider(store: FakeCredentialStore()).credentials()

    #expect(first.caCertificatePEM != second.caCertificatePEM)
    #expect(first.serverKeyPEM != second.serverKeyPEM)
}
