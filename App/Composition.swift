import Foundation
import os
import PadApplication
import PadDomain
import PadGuest
import PadInfrastructure
import PadInterface

enum CompositionError: Error {
    case tailnetAddressNotFound
}

private struct SystemIDGenerator: IDGenerator {
    func generate() -> UUID {
        UUID()
    }
}

// guest に繋がらないときと, 測れないプロジェクトは nil を返す.
private struct DockerUsageSource: UsageSource {
    let readUsages: @Sendable () async throws -> [String: ContainerUsage]
    let timeSource: any TimeSource

    func usage(of project: ProjectName) async -> ProjectUsage? {
        do {
            guard let measured = try await readUsages()[project.value] else { return nil }
            return try ProjectUsage(
                cpuUsage: measured.cpuUsage, memoryBytes: measured.memoryBytes, measuredAt: timeSource.now())
        } catch {
            return nil
        }
    }
}

private struct SystemTimeSource: TimeSource {
    func now() -> Date {
        Date()
    }
}

enum Composition {
    // 配信は tailnet の外から relay 経由で届く loopback の port, 管理は tailnet 側の port で受ける.
    static let deliveryPort = 8080
    static let adminPort = 8081

    private static let logger = Logger(subsystem: "PadServer", category: "composition")
    private static let guest = GuestHost()

    static func startGuest() async {
        await guest.startReportingFailure()
    }

    // メモリと disk の使用は port が無いので測れないとして返す.
    static func guestStatus() async -> GuestStatusReading? {
        GuestStatusReading(state: await guest.state(), memoryBytes: nil, diskBytes: nil)
    }

    static func run(logBus: any LogBus) async {
        do {
            try await makeServers(logBus: logBus).run()
        } catch {
            logger.error("servers stopped: \(error)")
        }
    }

    static func listProjects() async throws -> [ListProjects.Status] {
        try await ListProjects(storage: FileProjectStorage(directory: storageDirectory()))()
    }

    static func projectUsage(of name: String) async throws -> ProjectUsage? {
        try await GetProjectUsage(
            storage: FileProjectStorage(directory: storageDirectory()), usageSource: usageSource())(
                of: ProjectName(name))
    }

    private static func usageSource() -> DockerUsageSource {
        DockerUsageSource(readUsages: { try await guest.projectUsages() }, timeSource: SystemTimeSource())
    }

    private static func storageDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        ).appendingPathComponent("PadServer")
    }

    private static func makeServers(logBus: any LogBus) throws -> PadServers {
        let directory = try storageDirectory()
        guard let tailnetAddress = tailnetAddress() else {
            throw CompositionError.tailnetAddressNotFound
        }
        return PadServers(
            ports: PadServerPorts(delivery: deliveryPort, admin: adminPort, tailnetAddress: tailnetAddress),
            storage: FileProjectStorage(directory: directory),
            secretStore: KeychainSecretStore(),
            idGenerator: SystemIDGenerator(),
            logBus: logBus,
            fileStore: DiskFileStore(directory: directory.appendingPathComponent("files")),
            linkStore: FileShareLinkStore(directory: directory),
            timeSource: SystemTimeSource(),
            usageSource: usageSource())
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
