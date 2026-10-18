import PadApplication
import UIKit

/// サーバーの起動を持ち, 前面に戻るたびに待ち受けを確かめて, 止まっていれば起動し直します.
@MainActor
final class Lifecycle {
    private let logBus: any LogBus
    private var serverTask: Task<Void, Never>?
    private var guestTask: Task<Void, Never>?

    init(logBus: any LogBus) {
        self.logBus = logBus
    }

    func becomeActive() {
        UIApplication.shared.isIdleTimerDisabled = true
        if serverTask != nil, Self.isListening(port: Composition.deliveryPort) {
            return
        }
        if guestTask == nil {
            guestTask = Task { await Composition.startGuest() }
        }
        serverTask?.cancel()
        serverTask = Task { [logBus] in await Composition.run(logBus: logBus) }
    }

    func enterBackground() {
        UIApplication.shared.isIdleTimerDisabled = false
    }

    /// loopback の port に接続できるかを返します. loopback の接続は, 受け付けるか拒まれるかをすぐに返します.
    private nonisolated static func isListening(port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
