import Foundation
@testable import PadGuest
import Testing

private enum Constants {
    static let artifactsVariable = "PADSERVER_GUEST_ARTIFACTS"
    // guest の init が 192.168.100.100 を固定で設定するので、slirp の network を合わせる
    static let networkBackend = "user,id=net0,net=192.168.100.0/24,dhcpstart=192.168.100.100"
    static let cpuCount = 4
    static let dockerPort: UInt16 = 2376
    static let nginxGuestPort: UInt16 = 8080
    static let diskSizeBytes: UInt64 = 4_294_967_296
    static let readinessSeconds = 300
    static let readinessTimeout = Duration.seconds(readinessSeconds)
    static let httpAttempts = 30
    static let httpRetryInterval = Duration.seconds(1)
    static let serialTailLength = 3000
    static let okStatus = 200
    static let nginxImage = "nginx:alpine"
    static let containerName = "padserver-it-nginx"
}

private struct GuestArtifacts {
    let kernel: URL
    let initrd: URL
    let library: URL
    let biosDirectory: URL
    let nginxImageTar: URL

    static func locate() -> GuestArtifacts? {
        guard let path = ProcessInfo.processInfo.environment[Constants.artifactsVariable], !path.isEmpty else {
            return nil
        }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        let artifacts = GuestArtifacts(
            kernel: directory.appendingPathComponent("bzImage"),
            initrd: directory.appendingPathComponent("initrd.img"),
            library: directory.appendingPathComponent("libqemu-x86_64.dylib"),
            biosDirectory: directory.appendingPathComponent("pc-bios", isDirectory: true),
            nginxImageTar: directory.appendingPathComponent("nginx-alpine.tar"))
        let required = [
            artifacts.kernel, artifacts.initrd, artifacts.library, artifacts.biosDirectory, artifacts.nginxImageTar,
        ]
        return required.allSatisfy { FileManager.default.fileExists(atPath: $0.path) } ? artifacts : nil
    }
}

private actor InMemoryCredentialStore: CredentialStore {
    private var data: Data?

    func load() -> Data? { data }
    func save(_ data: Data) { self.data = data }
}

@available(macOS 15, iOS 18, *)
private struct Guest {
    let controller: QEMUGuestController
    let forwarder: PortForwarder
    let provider: GuestCredentialsProvider
    let serialLog: URL
}

@available(macOS 15, iOS 18, *)
private func makeGuest(artifacts: GuestArtifacts, workDirectory: URL) throws -> Guest {
    let serialLog = workDirectory.appendingPathComponent("serial.log")
    // 他の guest と monitor の port が衝突しないように、空いている port を選ぶ
    let monitorPort = try PortForwarder.freeLoopbackPort()
    let monitor = QEMUMonitor(port: monitorPort)
    let forwarder = PortForwarder(monitor: monitor)
    let provider = GuestCredentialsProvider(store: InMemoryCredentialStore())
    let readiness = GuestDockerReadiness(
        guestPort: Constants.dockerPort, forwarder: forwarder, credentials: { try await provider.credentials() })
    let controller = QEMUGuestController(
        runner: QEMURunner(libraryPath: artifacts.library.path, biosDirectory: artifacts.biosDirectory.path),
        monitor: monitor,
        disk: GuestDisk(applicationSupportURL: workDirectory),
        diskSizeBytes: Constants.diskSizeBytes,
        arguments: { diskPath in
            QEMUArguments(
                memory: "2G", cpuCount: Constants.cpuCount, maxCPUCount: Constants.cpuCount,
                kernelPath: artifacts.kernel.path,
                initrdPath: artifacts.initrd.path, diskPath: diskPath, networkBackend: Constants.networkBackend)
        },
        additionalArguments: [
            "-display", "none", "-no-reboot", "-serial", "file:\(serialLog.path)",
            "-monitor", "tcp:127.0.0.1:\(monitorPort),server,nowait",
        ],
        credentials: { try await provider.credentials() },
        isDockerReady: { await readiness.isReady() },
        readinessTimeout: Constants.readinessTimeout)
    return Guest(controller: controller, forwarder: forwarder, provider: provider, serialLog: serialLog)
}

@available(macOS 15, iOS 18, *)
@Test(
    .enabled(if: GuestArtifacts.locate() != nil, "set PADSERVER_GUEST_ARTIFACTS to the QEMU artifacts directory"),
    .timeLimit(.minutes(15)))
func guestRunsNginxAndServesHTTPThroughForwardedPort() async throws {
    let artifacts = try #require(GuestArtifacts.locate())
    let workDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("padserver-guest-it-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
    defer { removeQuietly(workDirectory) }
    let guest = try makeGuest(artifacts: artifacts, workDirectory: workDirectory)

    let status: Int
    do {
        try await guest.controller.start()
        status = try await serveNginx(on: guest, imageTar: artifacts.nginxImageTar)
    } catch {
        Issue.record("guest flow failed: \(error). serial log tail:\n\(serialTail(guest.serialLog))")
        await stopRecordingFailure(guest.controller)
        throw error
    }
    try await guest.controller.stop()
    #expect(status == Constants.okStatus)
}

/// image を読み込んで container を動かし、転送した port の HTTP の状態コードを返す. container は片付ける.
@available(macOS 15, iOS 18, *)
private func serveNginx(on guest: Guest, imageTar: URL) async throws -> Int {
    let dockerHostPort = try guest.forwarder.open(guestPort: Constants.dockerPort)
    let docker = try DockerClient(hostPort: dockerHostPort, credentials: try await guest.provider.credentials())
    try await docker.loadImage(fromFile: imageTar)

    let binding = ContainerPortBinding(hostPort: String(Constants.nginxGuestPort))
    let id = try await docker.createContainer(
        CreateContainerRequest(
            image: Constants.nginxImage, exposedPorts: ["80/tcp"],
            hostConfig: ContainerHostConfig(portBindings: ["80/tcp": [binding]])),
        name: Constants.containerName)
    try await docker.startContainer(id: id)

    let nginxHostPort = try guest.forwarder.open(guestPort: Constants.nginxGuestPort)
    let status = try await httpStatus(hostPort: nginxHostPort)

    try await docker.stopContainer(id: id)
    try await docker.removeContainer(id: id)
    return status
}

private func httpStatus(hostPort: UInt16) async throws -> Int {
    let url = try #require(URL(string: "http://127.0.0.1:\(hostPort)/"))
    var lastError: any Error = URLError(.cannotConnectToHost)
    for _ in 0..<Constants.httpAttempts {
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            if let http = response as? HTTPURLResponse { return http.statusCode }
        } catch {
            lastError = error
        }
        try await Task.sleep(for: Constants.httpRetryInterval)
    }
    throw lastError
}

@available(macOS 15, iOS 18, *)
private func stopRecordingFailure(_ controller: QEMUGuestController) async {
    do {
        try await controller.stop()
    } catch {
        Issue.record("could not stop the guest: \(error)")
    }
}

private func serialTail(_ url: URL) -> String {
    do {
        return String(try String(contentsOf: url, encoding: .utf8).suffix(Constants.serialTailLength))
    } catch {
        return "(no serial log)"
    }
}

private func removeQuietly(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("could not remove \(url.path): \(error)")
    }
}
