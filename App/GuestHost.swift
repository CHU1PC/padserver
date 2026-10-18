import Foundation
import os
import PadApplication
import PadDomain
import PadGuest

/// PadGuest の QEMUGuestController を, PadServerCore の GuestController に写します.
/// 成果物が無いときは QEMU を起動せず, 状態を failed にします.
actor GuestHost: GuestController {
    enum BootError: Error, Equatable {
        case artifactMissing(String)
    }

    private enum Constants {
        static let memory = "2G"
        static let cpuCount = 4
        static let diskSizeGigabytes: UInt64 = 16
        static let bytesPerGigabyte: UInt64 = 1_073_741_824
        static let readinessTimeoutSeconds = 180
        static let monitorPort = 10045
        static let qemuFramework = "qemu-x86_64-softmmu"
        static let networkBackend = "user,id=net0"
        static let monitorArguments = ["-nographic", "-monitor", "tcp:127.0.0.1:\(monitorPort),server,nowait"]
    }

    private static let logger = Logger(subsystem: "PadServer", category: "guest")

    private let kernel: URL
    private let initrd: URL
    private let qemuLibrary: URL
    private let controller: QEMUGuestController
    private var bootFailed = false

    init(bundle: Bundle = .main) {
        let guestDirectory = (bundle.resourceURL ?? bundle.bundleURL).appendingPathComponent("guest")
        let frameworks = bundle.privateFrameworksURL ?? bundle.bundleURL.appendingPathComponent("Frameworks")
        let kernel = guestDirectory.appendingPathComponent("bzImage")
        let initrd = guestDirectory.appendingPathComponent("initrd.img")
        let qemuLibrary = frameworks.appendingPathComponent("\(Constants.qemuFramework).framework")
            .appendingPathComponent(Constants.qemuFramework)
        self.kernel = kernel
        self.initrd = initrd
        self.qemuLibrary = qemuLibrary
        controller = QEMUGuestController(
            runner: QEMURunner(
                libraryPath: qemuLibrary.path, biosDirectory: guestDirectory.appendingPathComponent("pc-bios").path),
            monitor: QEMUMonitor(),
            disk: GuestDisk(),
            diskSizeBytes: Constants.diskSizeGigabytes * Constants.bytesPerGigabyte,
            arguments: { diskPath in
                QEMUArguments(
                    memory: Constants.memory, cpuCount: Constants.cpuCount, maxCPUCount: Constants.cpuCount,
                    kernelPath: kernel.path, initrdPath: initrd.path, diskPath: diskPath,
                    networkBackend: Constants.networkBackend)
            },
            additionalArguments: Constants.monitorArguments,
            // #383 の鍵の受け渡しが入るまで, Docker の応答は確かめられない.
            isDockerReady: { false },
            readinessTimeout: .seconds(Constants.readinessTimeoutSeconds))
    }

    func state() async -> GuestState {
        if bootFailed { return .failed }
        switch await controller.state() {
        case .stopped: return .stopped
        case .starting: return .starting
        case .ready: return .ready
        case .failed: return .failed
        }
    }

    func start() async throws {
        do {
            for artifact in [kernel, initrd, qemuLibrary]
            where !FileManager.default.fileExists(atPath: artifact.path) {
                throw BootError.artifactMissing(artifact.lastPathComponent)
            }
            try await controller.start()
        } catch {
            bootFailed = true
            throw error
        }
    }

    func stop() async throws {
        try await controller.stop()
    }

    /// 起動を試み, 失敗はログに残して握りつぶさずに state の failed として見せます.
    func startReportingFailure() async {
        do {
            try await start()
        } catch {
            Self.logger.error("guest failed to start: \(String(describing: error))")
        }
    }
}
