import Darwin
import Foundation
@testable import PadGuest
import Testing

@Test(.timeLimit(.minutes(1)))
func qemuMonitorSendsHMPCommandsToLoopback() async throws {
    let usernet = "Hub 0 (net0):\r\nTCP[HOST_FORWARD] 15 127.0.0.1 8080 10.0.2.15 80 0 0\r\n"
    let server = try FakeHMPServer(exchanges: [
        .init(command: "info status", response: "VM status: running\r\n"),
        .init(command: "system_powerdown", response: ""),
        .init(command: "hostfwd_add net0 tcp:127.0.0.1:8080-:80", response: ""),
        .init(command: "info usernet", response: usernet),
        .init(command: "hostfwd_remove net0 tcp:127.0.0.1:8080", response: "host forwarding rule removed\r\n"),
        .init(command: "quit", response: "", closesConnection: true),
    ])
    let running = Task.detached { server.run() }
    let monitor = QEMUMonitor(port: server.port)

    #expect(try monitor.status() == .running)
    try monitor.systemPowerdown()
    try monitor.addPortForward(hostPort: 8080, guestPort: 80)
    try monitor.removePortForward(hostPort: 8080)
    try monitor.quit()
    #expect(await running.value)
}

@Test(.timeLimit(.minutes(1)))
func qemuMonitorRejectsUninstalledPortForward() async throws {
    let usernet = "Hub 0 (net0):\r\nTCP[HOST_FORWARD] 15 127.0.0.1 8080 10.0.2.15 22 0 0\r\n"
    let server = try FakeHMPServer(exchanges: [
        .init(command: "hostfwd_add net0 tcp:127.0.0.1:8080-:80", response: ""),
        .init(command: "info usernet", response: usernet),
    ])
    let running = Task.detached { server.run() }
    let monitor = QEMUMonitor(port: server.port)

    #expect(throws: QEMUMonitor.MonitorError.commandFailed("host forwarding rule was not installed")) {
        try monitor.addPortForward(hostPort: 8080, guestPort: 80)
    }
    #expect(await running.value)
}

@Test(.timeLimit(.minutes(1)))
func qemuMonitorReportsPausedStateAndCommandFailure() async throws {
    let server = try FakeHMPServer(exchanges: [
        .init(command: "info status", response: "VM status: paused\r\n"),
        .init(command: "hostfwd_remove net0 tcp:127.0.0.1:8080", response: "host forwarding rule not found\r\n"),
    ])
    let running = Task.detached { server.run() }
    let monitor = QEMUMonitor(port: server.port)

    #expect(try monitor.status() == .paused)
    #expect(throws: QEMUMonitor.MonitorError.commandFailed("host forwarding rule not found\r\n(qemu) ")) {
        try monitor.removePortForward(hostPort: 8080)
    }
    #expect(await running.value)
}

private struct FakeHMPServer: Sendable {
    private static let newlineByte: UInt8 = 10

    struct Exchange: Sendable {
        let command: String
        let response: String
        var closesConnection = false
    }

    private let listener: Int32
    let port: UInt16
    let exchanges: [Exchange]

    init(exchanges: [Exchange]) throws {
        let listener = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard listener >= 0 else { throw ServerError.socketFailed }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let parsed = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard parsed == 1 else {
            Darwin.close(listener)
            throw ServerError.socketFailed
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(listener, 1) == 0 else {
            Darwin.close(listener)
            throw ServerError.socketFailed
        }
        guard let assignedPort = Self.assignedPort(for: listener) else {
            Darwin.close(listener)
            throw ServerError.socketFailed
        }
        self.listener = listener
        port = assignedPort
        self.exchanges = exchanges
    }

    private static func assignedPort(for listener: Int32) -> UInt16? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.getsockname(listener, $0, &length)
            }
        }
        guard resolved == 0 else { return nil }
        return UInt16(bigEndian: address.sin_port)
    }

    func run() -> Bool {
        defer { Darwin.close(listener) }
        do {
            for exchange in exchanges {
                try serve(exchange)
            }
            return true
        } catch {
            Issue.record("Fake HMP server failed: \(error)")
            return false
        }
    }

    private func serve(_ exchange: Exchange) throws {
        let connection = Darwin.accept(listener, nil, nil)
        guard connection >= 0 else { throw ServerError.socketFailed }
        defer { Darwin.close(connection) }
        try write("(qemu) ", to: connection)
        var request = [UInt8]()
        var byte: UInt8 = 0
        while Darwin.recv(connection, &byte, 1, 0) == 1 {
            if byte == Self.newlineByte { break }
            request.append(byte)
        }
        guard String(bytes: request, encoding: .utf8) == exchange.command else {
            throw ServerError.unexpectedCommand
        }
        if !exchange.closesConnection {
            try write(exchange.response + "(qemu) ", to: connection)
        }
    }

    private func write(_ value: String, to connection: Int32) throws {
        let bytes = [UInt8](value.utf8)
        let count = bytes.withUnsafeBytes { Darwin.send(connection, $0.baseAddress, bytes.count, 0) }
        guard count == bytes.count else { throw ServerError.socketFailed }
    }

    private enum ServerError: Error {
        case socketFailed
        case unexpectedCommand
    }
}
