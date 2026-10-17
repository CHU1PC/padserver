import Darwin

public struct PortForwarder: Sendable {
    public enum ForwardError: Error, Equatable, Sendable {
        case noFreePort
    }

    private let monitor: QEMUMonitor
    private let allocatePort: @Sendable () throws -> UInt16

    public init(monitor: QEMUMonitor = QEMUMonitor()) {
        self.monitor = monitor
        allocatePort = Self.freeLoopbackPort
    }

    init(monitor: QEMUMonitor, allocatePort: @escaping @Sendable () throws -> UInt16) {
        self.monitor = monitor
        self.allocatePort = allocatePort
    }

    /// guest の port を loopback の空いた port に出して, その host 側の port を返す.
    public func open(guestPort: UInt16) throws -> UInt16 {
        let hostPort = try allocatePort()
        try monitor.addPortForward(hostPort: hostPort, guestPort: guestPort)
        return hostPort
    }

    public func close(hostPort: UInt16) throws {
        try monitor.removePortForward(hostPort: hostPort)
    }

    static func freeLoopbackPort() throws -> UInt16 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ForwardError.noFreePort }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        let parsed = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard parsed == 1 else { throw ForwardError.noFreePort }
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, size) }
        }
        guard bound == 0 else { throw ForwardError.noFreePort }
        var length = size
        let resolved = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.getsockname(descriptor, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        guard resolved == 0, port != 0 else { throw ForwardError.noFreePort }
        return port
    }
}
