import Darwin
@testable import PadGuest
import Testing

@Test(.timeLimit(.minutes(1)))
func portForwarderOpensAndClosesLoopbackForward() async throws {
    let usernet = "Hub 0 (net0):\r\nTCP[HOST_FORWARD] 15 127.0.0.1 49152 10.0.2.15 80 0 0\r\n"
    let server = try FakeHMPServer(exchanges: [
        .init(command: "hostfwd_add net0 tcp:127.0.0.1:49152-:80", response: ""),
        .init(command: "info usernet", response: usernet),
        .init(command: "hostfwd_remove net0 tcp:127.0.0.1:49152", response: "host forwarding rule removed\r\n"),
    ])
    let running = server.start()
    let forwarder = PortForwarder(monitor: QEMUMonitor(port: server.port), allocatePort: { 49152 })

    let hostPort = try forwarder.open(guestPort: 80)
    try forwarder.close(hostPort: hostPort)

    #expect(hostPort == 49152)
    #expect(await running.value)
}

@Test(.timeLimit(.minutes(1)))
func portForwarderPropagatesMonitorFailure() async throws {
    let server = try FakeHMPServer(exchanges: [
        .init(command: "hostfwd_add net0 tcp:127.0.0.1:49152-:80", response: "invalid format\r\n")
    ])
    let running = server.start()
    let forwarder = PortForwarder(monitor: QEMUMonitor(port: server.port), allocatePort: { 49152 })

    #expect(throws: QEMUMonitor.MonitorError.commandFailed("invalid format\r\n(qemu) ")) {
        try forwarder.open(guestPort: 80)
    }
    #expect(await running.value)
}

@Test
func portForwarderAllocatesFreeLoopbackPort() throws {
    let port = try PortForwarder.freeLoopbackPort()

    #expect(port != 0)
    #expect(try canBindLoopback(port))
}

private func canBindLoopback(_ port: UInt16) throws -> Bool {
    let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { return false }
    defer { Darwin.close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = port.bigEndian
    _ = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
    let size = socklen_t(MemoryLayout<sockaddr_in>.size)
    return withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
    } == 0
}
