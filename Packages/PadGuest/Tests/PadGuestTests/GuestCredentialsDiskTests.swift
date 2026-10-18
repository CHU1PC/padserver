import Foundation
import PadGuest
import Testing

private struct FixedStore: CredentialStore {
    let data: Data

    func load() -> Data? {
        data
    }

    func save(_ data: Data) {
        Issue.record("The fixed store must not be saved to.")
    }
}

private func makeCredentials() async throws -> GuestCredentials {
    let token = UUID().uuidString
    let fields = [
        "caCertificatePEM": "ca-\(token)\n", "serverCertificatePEM": "server-\(token)\n",
        "serverKeyPEM": "server-key-\(token)\n", "clientCertificatePEM": "client-\(token)\n",
        "clientKeyPEM": "client-key-\(token)\n",
    ]
    let store = FixedStore(data: try JSONEncoder().encode(fields))
    return try await GuestCredentialsProvider(store: store).credentials()
}

private func makeDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("padguest-cred-tests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeDirectory(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Could not remove the temporary credentials test directory.")
    }
}

private func runTar(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    process.arguments = arguments
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return try #require(String(bytes: data, encoding: .utf8))
}

@Test func archiveHoldsOnlyServerSideFilesWithExactContent() async throws {
    let credentials = try await makeCredentials()
    let directory = try makeDirectory()
    defer { removeDirectory(directory) }
    let tarURL = directory.appendingPathComponent("cred.tar")
    try GuestCredentialsDisk.archive(credentials).write(to: tarURL)

    let listing = try runTar(["-tvf", tarURL.path])
    let names = listing.split(separator: "\n").compactMap { $0.split(separator: " ").last.map(String.init) }
    #expect(names == ["ca.pem", "server.pem", "server-key.pem"])
    #expect(listing.split(separator: "\n").allSatisfy { $0.hasPrefix("-rw-------") })

    let extractDirectory = directory.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: extractDirectory, withIntermediateDirectories: true)
    _ = try runTar(["-xf", tarURL.path, "-C", extractDirectory.path])
    func content(_ name: String) throws -> String {
        try String(contentsOf: extractDirectory.appendingPathComponent(name), encoding: .utf8)
    }
    #expect(try content("ca.pem") == credentials.caCertificatePEM)
    #expect(try content("server.pem") == credentials.serverCertificatePEM)
    #expect(try content("server-key.pem") == credentials.serverKeyPEM)
}

@Test func archiveDoesNotContainClientMaterial() async throws {
    let credentials = try await makeCredentials()
    let archive = try #require(String(bytes: GuestCredentialsDisk.archive(credentials), encoding: .utf8))

    #expect(!archive.contains(credentials.clientKeyPEM))
    #expect(!archive.contains(credentials.clientCertificatePEM))
}

@Test func archiveIsBlockAlignedWithTrailingZeroBlocks() async throws {
    let archive = GuestCredentialsDisk.archive(try await makeCredentials())

    #expect(archive.count % 512 == 0)
    #expect(archive.suffix(1024).allSatisfy { $0 == 0 })
}

@Test func writeCreatesPrivateFileAndRemoveDeletesIt() async throws {
    let directory = try makeDirectory()
    defer { removeDirectory(directory) }

    let disk = try GuestCredentialsDisk.write(try await makeCredentials(), directory: directory)

    #expect(disk.url.deletingLastPathComponent().path == directory.path)
    let attributes = try FileManager.default.attributesOfItem(atPath: disk.url.path)
    #expect(attributes[.posixPermissions] as? Int == 0o600)
    #expect(try Data(contentsOf: disk.url).count % 512 == 0)

    try disk.remove()
    #expect(!FileManager.default.fileExists(atPath: disk.url.path))
}

@Test func writeUsesDistinctRandomNames() async throws {
    let directory = try makeDirectory()
    defer { removeDirectory(directory) }

    let first = try GuestCredentialsDisk.write(try await makeCredentials(), directory: directory)
    let second = try GuestCredentialsDisk.write(try await makeCredentials(), directory: directory)

    #expect(first.url != second.url)
}

@Test func additionalArgumentsAttachReadOnlyDrive() async throws {
    let directory = try makeDirectory()
    defer { removeDirectory(directory) }

    let disk = try GuestCredentialsDisk.write(try await makeCredentials(), directory: directory)

    #expect(
        disk.additionalArguments == [
            "-drive", "file=\(disk.url.path),id=cred,if=none,format=raw,readonly=on",
            "-device", "virtio-blk-pci,drive=cred",
        ])
}
