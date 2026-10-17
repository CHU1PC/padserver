import Darwin
import Foundation

public struct QEMUMonitor: Sendable {
    public enum Status: Equatable, Sendable {
        case running
        case paused
    }

    public enum MonitorError: Error, Equatable, Sendable {
        case connectionFailed
        case disconnected
        case invalidResponse
        case commandFailed(String)
    }

    private enum Constants {
        static let monitorPort: UInt16 = 10045
        static let timeoutSeconds = 5
        static let responseLimit = 65_536
        static let readChunkSize = 4096
        static let prompt = Data("(qemu) ".utf8)
        static let forwardFieldCount = 6
        static let forwardHostAddressIndex = 2
        static let forwardHostPortIndex = 3
        static let forwardGuestPortIndex = 5
    }

    private let port: UInt16

    public init() {
        port = Constants.monitorPort
    }

    init(port: UInt16) {
        self.port = port
    }

    public func status() throws -> Status {
        let response = try command("info status")
        if response.contains("VM status: running") {
            return .running
        }
        if response.contains("VM status: paused") {
            return .paused
        }
        throw MonitorError.invalidResponse
    }

    public func systemPowerdown() throws {
        try command("system_powerdown")
    }

    public func quit() throws {
        try command("quit", allowDisconnect: true)
    }

    public func addPortForward(hostPort: UInt16, guestPort: UInt16) throws {
        try command("hostfwd_add net0 tcp:127.0.0.1:\(hostPort)-:\(guestPort)")
        let rules = try command("info usernet")
        let found = rules.split(whereSeparator: \.isNewline).contains { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            return fields.count >= Constants.forwardFieldCount
                && fields[0] == "TCP[HOST_FORWARD]"
                && fields[Constants.forwardHostAddressIndex] == "127.0.0.1"
                && fields[Constants.forwardHostPortIndex] == String(hostPort)
                && fields[Constants.forwardGuestPortIndex] == String(guestPort)
        }
        guard found else { throw MonitorError.commandFailed("host forwarding rule was not installed") }
    }

    public func removePortForward(hostPort: UInt16) throws {
        try command("hostfwd_remove net0 tcp:127.0.0.1:\(hostPort)")
    }

    @discardableResult
    private func command(_ value: String, allowDisconnect: Bool = false) throws -> String {
        let descriptor = try connect()
        defer { Darwin.close(descriptor) }
        _ = try readResponse(from: descriptor)
        try send(Data((value + "\n").utf8), to: descriptor)
        let response = try readResponse(from: descriptor, allowDisconnect: allowDisconnect)
        guard let text = String(data: response, encoding: .utf8) else {
            throw MonitorError.invalidResponse
        }
        let lowered = text.lowercased()
        let failureMarkers = ["error:", "failed", "not found", "invalid format", "unknown command"]
        if failureMarkers.contains(where: { lowered.contains($0) }) {
            throw MonitorError.commandFailed(text)
        }
        return text
    }

    private func connect() throws -> Int32 {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw MonitorError.connectionFailed }
        guard Self.configureSocket(descriptor) else {
            Darwin.close(descriptor)
            throw MonitorError.connectionFailed
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        let parsed = "127.0.0.1".withCString { inet_pton(AF_INET, $0, &address.sin_addr) }
        guard parsed == 1 else {
            Darwin.close(descriptor)
            throw MonitorError.connectionFailed
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw MonitorError.connectionFailed
        }
        return descriptor
    }

    private static func configureSocket(_ descriptor: Int32) -> Bool {
        var timeout = timeval(tv_sec: Constants.timeoutSeconds, tv_usec: 0)
        var noSIGPIPE: Int32 = 1
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
            && setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    private func send(_ data: Data, to descriptor: Int32) throws {
        var sent = 0
        while sent < data.count {
            let written = data.withUnsafeBytes { bytes in
                Darwin.send(descriptor, bytes.baseAddress?.advanced(by: sent), data.count - sent, 0)
            }
            if written < 0 && errno == EINTR { continue }
            guard written > 0 else { throw MonitorError.disconnected }
            sent += written
        }
    }

    private func readResponse(from descriptor: Int32, allowDisconnect: Bool = false) throws -> Data {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: Constants.readChunkSize)
        while response.count < Constants.responseLimit {
            let received = Darwin.recv(descriptor, &buffer, buffer.count, 0)
            if received < 0 && errno == EINTR { continue }
            if received == 0 {
                if allowDisconnect { return response }
                throw MonitorError.disconnected
            }
            guard received > 0 else { throw MonitorError.disconnected }
            response.append(contentsOf: buffer[..<received])
            if response.suffix(Constants.prompt.count) == Constants.prompt {
                return response
            }
        }
        throw MonitorError.invalidResponse
    }
}
