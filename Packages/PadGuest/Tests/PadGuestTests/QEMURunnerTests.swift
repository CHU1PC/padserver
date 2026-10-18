import Foundation
import PadGuest
import Testing

private let stubSource = """
    #include <stdio.h>
    #include <stdlib.h>

    static FILE *open_log(void) { return fopen(getenv("PADGUEST_STUB_LOG"), "a"); }

    void qemu_init(int argc, char **argv) {
        FILE *log = open_log();
        fprintf(log, "init %d\\n", argc);
        for (int i = 0; i < argc; i++) { fprintf(log, "arg %s\\n", argv[i]); }
        fclose(log);
    }

    int qemu_main_loop(void) { return \(Constants.stubExitStatus); }

    void qemu_cleanup(int status) {
        FILE *log = open_log();
        fprintf(log, "cleanup %d\\n", status);
        fclose(log);
    }
    """

private let unlockFunctionSource = """
    void bql_unlock(void) {
        FILE *log = open_log();
        fprintf(log, "unlock\\n");
        fclose(log);
    }
    """

// 本物の QEMU の library は, dlopen の constructor が RCU の reader として登録する thread と,
// qemu_init を呼ぶ thread が同じでないと, 登録した thread の終了後に call_rcu が壊れる (#402).
private let threadStubSource = """
    #include <pthread.h>
    #include <stdio.h>
    #include <stdlib.h>

    static void log_thread(const char *label) {
        uint64_t tid = 0;
        pthread_threadid_np(NULL, &tid);
        FILE *log = fopen(getenv("PADGUEST_THREAD_LOG"), "a");
        fprintf(log, "%s %llu\\n", label, tid);
        fclose(log);
    }

    __attribute__((constructor)) static void on_load(void) { log_thread("load"); }
    void qemu_init(int argc, char **argv) { log_thread("init"); }
    int qemu_main_loop(void) { return 0; }
    void qemu_cleanup(int status) { log_thread("cleanup"); }
    """

private enum Constants {
    static let stubExitStatus = 7
    static let logTimeout: TimeInterval = 10
    static let logPollMilliseconds = 50
    static let cpuCount = 2
    static let maxCPUCount = 4
}

private let initOnlySource = "void qemu_init(int argc, char **argv) {}\n"

private let qemuArguments = QEMUArguments(
    memory: "1G",
    cpuCount: Constants.cpuCount,
    maxCPUCount: Constants.maxCPUCount,
    kernelPath: "/guest/bzImage",
    initrdPath: "/guest/initrd.img",
    diskPath: "/guest/root.img",
    networkBackend: "user,id=net0"
)

private func makeWorkDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("padguest-runner-tests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeWorkDirectory(_ url: URL) {
    do {
        try FileManager.default.removeItem(at: url)
    } catch {
        Issue.record("Could not remove the temporary runner test directory.")
    }
}

private func compileDylib(source: String, in directory: URL, name: String) throws -> String {
    let sourceURL = directory.appendingPathComponent("\(name).c")
    try source.write(to: sourceURL, atomically: true, encoding: .utf8)
    let dylibURL = directory.appendingPathComponent("\(name).dylib")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["clang", "-dynamiclib", sourceURL.path, "-o", dylibURL.path]
    try process.run()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    return dylibURL.path
}

private func logText(at url: URL) throws -> String {
    guard FileManager.default.fileExists(atPath: url.path) else { return "" }
    return try String(contentsOf: url, encoding: .utf8)
}

private func readLog(at url: URL, until marker: String) async throws -> String {
    let deadline = Date().addingTimeInterval(Constants.logTimeout)
    while Date() < deadline {
        let text = try logText(at: url)
        if text.contains(marker) {
            return text
        }
        try await Task.sleep(for: .milliseconds(Constants.logPollMilliseconds))
    }
    return try logText(at: url)
}

@Test func qemuRunnerRejectsMissingLibrary() {
    let runner = QEMURunner(libraryPath: "/nonexistent/qemu.dylib", biosDirectory: "/guest/pc-bios")

    #expect(throws: QEMURunner.RunnerError.libraryNotFound("/nonexistent/qemu.dylib")) {
        try runner.start(arguments: qemuArguments)
    }
}

@Test func qemuRunnerRejectsFileThatIsNotLibrary() throws {
    let directory = try makeWorkDirectory()
    defer { removeWorkDirectory(directory) }
    let fileURL = directory.appendingPathComponent("not-a-library.dylib")
    try "text".write(to: fileURL, atomically: true, encoding: .utf8)
    let runner = QEMURunner(libraryPath: fileURL.path, biosDirectory: "/guest/pc-bios")

    #expect {
        try runner.start(arguments: qemuArguments)
    } throws: { error in
        guard case QEMURunner.RunnerError.libraryOpenFailed = error else { return false }
        return true
    }
}

@Test func qemuRunnerRejectsLibraryWithoutEntryPoint() throws {
    let directory = try makeWorkDirectory()
    defer { removeWorkDirectory(directory) }
    let path = try compileDylib(source: initOnlySource, in: directory, name: "init-only")
    let runner = QEMURunner(libraryPath: path, biosDirectory: "/guest/pc-bios")

    #expect(throws: QEMURunner.RunnerError.symbolNotFound("qemu_main_loop")) {
        try runner.start(arguments: qemuArguments)
    }
}

@Test func qemuRunnerPassesArgumentsAndRunsEntryPointsInOrder() async throws {
    // 環境変数を共有するので, 2 つの stub は順に動かす
    for (source, hasUnlock) in [(stubSource + unlockFunctionSource, true), (stubSource, false)] {
        let directory = try makeWorkDirectory()
        defer { removeWorkDirectory(directory) }
        let path = try compileDylib(source: source, in: directory, name: "stub")
        let logURL = directory.appendingPathComponent("stub.log")
        setenv("PADGUEST_STUB_LOG", logURL.path, 1)
        let additionalArguments = ["-display", "none"]
        let runner = QEMURunner(libraryPath: path, biosDirectory: "/guest/pc-bios")

        try runner.start(arguments: qemuArguments, additionalArguments: additionalArguments)

        let log = try await readLog(at: logURL, until: hasUnlock ? "unlock" : "cleanup")
        let expectedArguments = ["qemu-system", "-L", "/guest/pc-bios"] + qemuArguments.values + additionalArguments
        let expected =
            (["init \(expectedArguments.count)"] + expectedArguments.map { "arg \($0)" } + [
                "cleanup \(Constants.stubExitStatus)"
            ] + (hasUnlock ? ["unlock"] : []))
            .joined(separator: "\n") + "\n"
        #expect(log == expected)
    }
}

@Test func qemuRunnerLoadsLibraryOnTheThreadThatRunsQEMU() async throws {
    let directory = try makeWorkDirectory()
    defer { removeWorkDirectory(directory) }
    let path = try compileDylib(source: threadStubSource, in: directory, name: "thread-stub")
    let logURL = directory.appendingPathComponent("thread.log")
    setenv("PADGUEST_THREAD_LOG", logURL.path, 1)
    let runner = QEMURunner(libraryPath: path, biosDirectory: "/guest/pc-bios")

    try runner.start(arguments: qemuArguments)

    let log = try await readLog(at: logURL, until: "cleanup")
    let threads = Dictionary(
        uniqueKeysWithValues: log.split(separator: "\n").map { line -> (String, String) in
            let parts = line.split(separator: " ")
            return (String(parts[0]), String(parts[1]))
        })
    #expect(threads["load"] != nil)
    #expect(threads["load"] == threads["init"])
    #expect(threads["init"] == threads["cleanup"])
}
