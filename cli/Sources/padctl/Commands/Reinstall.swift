import ArgumentParser
import Foundation

protocol ReinstallCommandRunner {
    func run(_ executable: String, arguments: [String], in directory: URL) throws
}

struct SystemReinstallCommandRunner: ReinstallCommandRunner {
    func run(_ executable: String, arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
        process.currentDirectoryURL = directory
        try process.run()
        process.waitUntilExit()
        guard process.terminationReason == .exit, process.terminationStatus == 0 else {
            throw ReinstallError.commandFailed(executable, process.terminationStatus)
        }
    }
}

enum ReinstallError: Error, LocalizedError, Equatable {
    case missingDeviceID
    case appNotFound
    case commandFailed(String, Int32)

    var errorDescription: String? {
        switch self {
        case .missingDeviceID:
            return "Set deviceID in ~/.config/padctl/config.json before reinstalling."

        case .appNotFound:
            return "The build did not produce PadServer.app."

        case .commandFailed(let executable, let status):
            return "\(executable) failed with exit status \(status)."
        }
    }
}

struct ReinstallService {
    private let configStore: any ConfigStore
    private let runner: any ReinstallCommandRunner
    private let repositoryURL: URL
    private let temporaryDirectory: URL
    private let fileManager: FileManager

    init(
        configStore: any ConfigStore,
        runner: any ReinstallCommandRunner,
        repositoryURL: URL,
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        fileManager: FileManager = .default
    ) {
        self.configStore = configStore
        self.runner = runner
        self.repositoryURL = repositoryURL
        self.temporaryDirectory = temporaryDirectory
        self.fileManager = fileManager
    }

    func reinstall() throws {
        guard let deviceID = try configStore.load()?.deviceID, !deviceID.isEmpty else {
            throw ReinstallError.missingDeviceID
        }

        let derivedDataURL = temporaryDirectory.appendingPathComponent("padctl-reinstall-\(UUID().uuidString)")
        try fileManager.createDirectory(at: derivedDataURL, withIntermediateDirectories: true)
        defer {
            do {
                try fileManager.removeItem(at: derivedDataURL)
            } catch {
                FileHandle.standardError.write(Data("Could not remove temporary build data.\n".utf8))
            }
        }

        let appURL = try buildApp(derivedDataURL: derivedDataURL)
        try runner.run(
            "xcrun", arguments: ["devicectl", "device", "install", "app", "--device", deviceID, appURL.path],
            in: repositoryURL
        )
    }

    private func buildApp(derivedDataURL: URL) throws -> URL {
        try runner.run("xcodegen", arguments: ["generate"], in: repositoryURL)
        try runner.run(
            "xcodebuild",
            arguments: [
                "-project", "PadServer.xcodeproj",
                "-scheme", "PadServer",
                "-configuration", "Debug",
                "-sdk", "iphoneos",
                "-destination", "generic/platform=iOS",
                "-derivedDataPath", derivedDataURL.path,
                "build",
            ],
            in: repositoryURL
        )

        let appURL = derivedDataURL.appendingPathComponent("Build/Products/Debug-iphoneos/PadServer.app")
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: appURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ReinstallError.appNotFound
        }
        return appURL
    }
}

struct Reinstall: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Build PadServer and reinstall it on the configured iPad."
    )

    mutating func run() throws {
        let fileManager = FileManager.default
        let service = ReinstallService(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            runner: SystemReinstallCommandRunner(),
            repositoryURL: URL(fileURLWithPath: fileManager.currentDirectoryPath)
        )
        try service.reinstall()
        print("PadServer reinstalled.")
    }
}
