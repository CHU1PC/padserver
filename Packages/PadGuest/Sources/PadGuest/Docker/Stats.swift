import Foundation

public struct ContainerUsage: Equatable, Sendable {
    /// 1 コアを 1.0 とする割合. 複数コアを使うと 1.0 を超える.
    public let cpuUsage: Double
    /// page cache を除いた使用バイト数.
    public let memoryBytes: Int
}

private struct StatsCPUUsage: Decodable {
    let totalUsage: UInt64?
    let perCPUUsage: [UInt64]?

    private enum CodingKeys: String, CodingKey {
        case totalUsage = "total_usage"
        case perCPUUsage = "percpu_usage"
    }
}

private struct StatsCPU: Decodable {
    let cpuUsage: StatsCPUUsage?
    let systemCPUUsage: UInt64?
    let onlineCPUs: Int?

    private enum CodingKeys: String, CodingKey {
        case cpuUsage = "cpu_usage"
        case systemCPUUsage = "system_cpu_usage"
        case onlineCPUs = "online_cpus"
    }
}

private struct StatsMemory: Decodable {
    let usage: UInt64?
    let stats: [String: UInt64]?
}

private struct StatsResponse: Decodable {
    let cpuStats: StatsCPU?
    let preCPUStats: StatsCPU?
    let memoryStats: StatsMemory?

    private enum CodingKeys: String, CodingKey {
        case cpuStats = "cpu_stats"
        case preCPUStats = "precpu_stats"
        case memoryStats = "memory_stats"
    }
}

@available(macOS 13, iOS 16, *)
extension DockerClient {
    private enum StatsConstants {
        static let okStatus = 200
        static let notFoundStatus = 404
        static let composeProjectLabel = "com.docker.compose.project"
        // Docker CLI と同じ順. cgroup v1 の total_inactive_file, v2 の inactive_file, 古い v1 の cache
        static let cacheKeys = ["total_inactive_file", "inactive_file", "cache"]
    }

    /// 測れない container (消えた, memory の使用量が無い) は nil を返す. CPU だけ測れないときは 0 にする.
    public func containerUsage(id: String) async throws -> ContainerUsage? {
        let response = try await send(
            method: "GET", path: "/containers/\(id)/stats", query: [URLQueryItem(name: "stream", value: "false")])
        if response.status == StatsConstants.notFoundStatus { return nil }
        guard response.status == StatsConstants.okStatus else { throw ClientError.unexpectedStatus(response.status) }
        let stats: StatsResponse
        do {
            stats = try JSONDecoder().decode(StatsResponse.self, from: response.body)
        } catch {
            throw ClientError.invalidResponse
        }
        guard let memoryBytes = Self.memoryBytes(of: stats.memoryStats) else { return nil }
        return ContainerUsage(cpuUsage: Self.cpuUsage(of: stats), memoryBytes: memoryBytes)
    }

    /// compose のプロジェクト名ごとの合計. label の無い container と, 測れない container は数えない.
    public func projectUsages() async throws -> [String: ContainerUsage] {
        var totals: [String: ContainerUsage] = [:]
        for container in try await listContainers() {
            guard let project = container.labels[StatsConstants.composeProjectLabel],
                let usage = try await containerUsage(id: container.id)
            else { continue }
            let total = totals[project]
            totals[project] = ContainerUsage(
                cpuUsage: (total?.cpuUsage ?? 0) + usage.cpuUsage,
                memoryBytes: (total?.memoryBytes ?? 0) + usage.memoryBytes)
        }
        return totals
    }

    private static func cpuUsage(of stats: StatsResponse) -> Double {
        guard let current = stats.cpuStats, let previous = stats.preCPUStats,
            let currentTotal = current.cpuUsage?.totalUsage, let previousTotal = previous.cpuUsage?.totalUsage,
            let currentSystem = current.systemCPUUsage, let previousSystem = previous.systemCPUUsage,
            currentTotal >= previousTotal, currentSystem > previousSystem
        else { return 0 }
        let cores = current.onlineCPUs ?? current.cpuUsage?.perCPUUsage?.count ?? 1
        let cpuDelta = Double(currentTotal - previousTotal)
        let systemDelta = Double(currentSystem - previousSystem)
        return cpuDelta / systemDelta * Double(max(cores, 1))
    }

    private static func memoryBytes(of stats: StatsMemory?) -> Int? {
        guard let usage = stats?.usage else { return nil }
        let cache = StatsConstants.cacheKeys.lazy.compactMap { stats?.stats?[$0] }.first ?? 0
        return Int(clamping: usage > cache ? usage - cache : 0)
    }
}
