import Darwin
import Foundation

public struct QEMURunner: Sendable {
    public enum RunnerError: Error, Equatable, Sendable {
        case libraryNotFound(String)
        case libraryOpenFailed(String)
        case symbolNotFound(String)
    }

    private typealias InitFunction = @convention(c) (Int32, UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> Void
    private typealias MainLoopFunction = @convention(c) () -> Int32
    private typealias CleanupFunction = @convention(c) (Int32) -> Void

    private struct EntryPoints: Sendable {
        let qemuInit: InitFunction
        let qemuMainLoop: MainLoopFunction
        let qemuCleanup: CleanupFunction

        init(handle: UnsafeMutableRawPointer) throws {
            qemuInit = try Self.symbol("qemu_init", in: handle)
            qemuMainLoop = try Self.symbol("qemu_main_loop", in: handle)
            qemuCleanup = try Self.symbol("qemu_cleanup", in: handle)
        }

        private static func symbol<Function>(_ name: String, in handle: UnsafeMutableRawPointer) throws -> Function {
            guard let address = dlsym(handle, name) else {
                throw RunnerError.symbolNotFound(name)
            }
            return unsafeBitCast(address, to: Function.self)
        }
    }

    private enum Constants {
        static let programName = "qemu-system"
    }

    private let libraryPath: String
    private let biosDirectory: String

    public init(libraryPath: String, biosDirectory: String) {
        self.libraryPath = libraryPath
        self.biosDirectory = biosDirectory
    }

    public func start(arguments: QEMUArguments, additionalArguments: [String] = []) throws {
        guard FileManager.default.fileExists(atPath: libraryPath) else {
            throw RunnerError.libraryNotFound(libraryPath)
        }
        guard let handle = dlopen(libraryPath, RTLD_NOW) else {
            throw RunnerError.libraryOpenFailed(dlerror().map { String(cString: $0) } ?? "unknown")
        }
        let entryPoints: EntryPoints
        do {
            entryPoints = try EntryPoints(handle: handle)
        } catch {
            dlclose(handle)
            throw error
        }

        let values = [Constants.programName, "-L", biosDirectory] + arguments.values + additionalArguments
        let thread = Thread {
            var argv: [UnsafeMutablePointer<CChar>?] = values.map { strdup($0) }
            defer { argv.forEach { free($0) } }
            entryPoints.qemuInit(Int32(values.count), &argv)
            entryPoints.qemuCleanup(entryPoints.qemuMainLoop())
        }
        thread.qualityOfService = .userInteractive
        thread.start()
    }
}
