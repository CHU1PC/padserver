import Foundation
import Testing
@testable import padctl

@Test func reinstallCommandIsRegistered() throws {
    #expect(try Padctl.parseAsRoot(["reinstall"]) is Reinstall)
}

@Test func reinstallBuildsAndInstallsAppForConfiguredDevice() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("padctl-reinstall-tests-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        do {
            try FileManager.default.removeItem(at: directory)
        } catch {
            Issue.record("Could not remove the temporary reinstall test directory.")
        }
    }
    let configStore = ConfigFileStore(fileURL: directory.appendingPathComponent("config.json"))
    let serverURL = try #require(URL(string: "https://pad.example.com"))
    try configStore.save(PadctlConfig(serverURL: serverURL, deviceID: "example-device-id"))
    let runner = RecordingReinstallRunner()
    let repositoryURL = directory.appendingPathComponent("repository")
    let service = ReinstallService(
        configStore: configStore, runner: runner, repositoryURL: repositoryURL, temporaryDirectory: directory)

    try service.reinstall()

    try expectReinstallCalls(runner.calls, repositoryURL: repositoryURL, temporaryDirectory: directory)
}

private func expectReinstallCalls(
    _ calls: [ReinstallCall], repositoryURL: URL, temporaryDirectory: URL
) throws {
    #expect(calls.map(\.executable) == ["xcodegen", "xcodebuild", "xcrun"])
    #expect(calls.allSatisfy { $0.directory == repositoryURL })
    #expect(calls.first?.arguments == ["generate"])
    let build = try #require(calls.first { $0.executable == "xcodebuild" })
    let derivedDataPath = try #require(build.argument(after: "-derivedDataPath"))
    #expect(build.arguments.contains("PadServer.xcodeproj"))
    #expect(build.argument(after: "-scheme") == "PadServer")
    #expect(build.argument(after: "-configuration") == "Debug")
    #expect(build.argument(after: "-sdk") == "iphoneos")
    #expect(build.argument(after: "-destination") == "generic/platform=iOS")
    #expect(derivedDataPath.hasPrefix(temporaryDirectory.path))
    let install = try #require(calls.first { $0.executable == "xcrun" })
    let expectedPrefix = ["devicectl", "device", "install", "app", "--device"]
    #expect(Array(install.arguments.prefix(expectedPrefix.count)) == expectedPrefix)
    #expect(install.argument(after: "--device") == "example-device-id")
    #expect(install.arguments.last == "\(derivedDataPath)/Build/Products/Debug-iphoneos/PadServer.app")
    #expect(!FileManager.default.fileExists(atPath: derivedDataPath))
}

@Test func reinstallRequiresDeviceIDBeforeRunningCommands() throws {
    let config = try PadctlConfig(serverURL: #require(URL(string: "https://pad.example.com")))
    let store = ReinstallTestConfigStore(config: config)
    let runner = RecordingReinstallRunner()
    let service = ReinstallService(
        configStore: store, runner: runner, repositoryURL: FileManager.default.temporaryDirectory)

    #expect(throws: ReinstallError.missingDeviceID) {
        try service.reinstall()
    }
    #expect(runner.calls.isEmpty)
}

private struct ReinstallTestConfigStore: ConfigStore {
    let config: PadctlConfig?

    func load() -> PadctlConfig? { config }

    func save(_ config: PadctlConfig?) throws {
        Issue.record("Reinstall must not write the configuration.")
    }
}

private struct ReinstallCall {
    let executable: String
    let arguments: [String]
    let directory: URL

    func argument(after name: String) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }
}

private final class RecordingReinstallRunner: ReinstallCommandRunner {
    var calls: [ReinstallCall] = []

    func run(_ executable: String, arguments: [String], in directory: URL) throws {
        let call = ReinstallCall(executable: executable, arguments: arguments, directory: directory)
        calls.append(call)
        if executable == "xcodebuild", let derivedDataPath = call.argument(after: "-derivedDataPath") {
            let appURL = URL(fileURLWithPath: derivedDataPath)
                .appendingPathComponent("Build/Products/Debug-iphoneos/PadServer.app")
            try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        }
    }
}
