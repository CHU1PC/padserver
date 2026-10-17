import Foundation
import os
import PadApplication
import PadDomain
import PadInfrastructure

enum CompositionError: Error {
    case tailnetAddressNotFound
}

private struct SystemIDGenerator: IDGenerator {
    func generate() -> UUID {
        UUID()
    }
}

enum Composition {
    // 配信は tailnet の外から relay 経由で届く loopback の port, 管理は tailnet 側の port で受ける.
    private static let deliveryPort = 8080
    static let adminPort = 8081

    private static let logger = Logger(subsystem: "PadServer", category: "composition")

    static func run() async {
        do {
            try await makeServers().run()
        } catch {
            logger.error("servers stopped: \(error)")
        }
    }

    private static func makeServers() throws -> PadServers {
        let directory = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("PadServer")
        guard let tailnetAddress = tailnetAddress() else {
            throw CompositionError.tailnetAddressNotFound
        }
        return PadServers(
            ports: PadServerPorts(delivery: deliveryPort, admin: adminPort, tailnetAddress: tailnetAddress),
            storage: FileProjectStorage(directory: directory),
            secretStore: KeychainSecretStore(),
            idGenerator: SystemIDGenerator(),
            logBus: InMemoryLogBus())
    }

    /// tailnet の IPv4 の範囲に入る, 自分の interface の address を返します.
    static func tailnetAddress() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return nil }
        defer { freeifaddrs(head) }
        for entry in sequence(first: head, next: { $0.pointee.ifa_next }) {
            guard let socketAddress = entry.pointee.ifa_addr, socketAddress.pointee.sa_family == sa_family_t(AF_INET)
            else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                socketAddress, socklen_t(socketAddress.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                NI_NUMERICHOST)
            let bytes = host.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
            if result == 0, let address = String(validating: bytes, as: UTF8.self), ClientAddress(address).isInTailnet {
                return address
            }
        }
        return nil
    }
}
