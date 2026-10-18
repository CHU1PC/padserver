import Foundation
@testable import PadGuest
import Testing

// Docker Engine API の stats の応答の形に合わせた固定値 (ID は見本).
// 手計算: cpuDelta = 400_000_000 - 300_000_000 = 100_000_000, systemDelta = 2_000_000_000 - 1_000_000_000,
// 使用率 = 100_000_000 / 1_000_000_000 * 4 = 0.4. メモリ = 10_000_000 - 2_000_000 = 8_000_000.
private let statsV2JSON = """
    {"cpu_stats":{"cpu_usage":{"total_usage":400000000},"system_cpu_usage":2000000000,"online_cpus":4},\
    "precpu_stats":{"cpu_usage":{"total_usage":300000000},"system_cpu_usage":1000000000,"online_cpus":4},\
    "memory_stats":{"usage":10000000,"limit":1000000000,"stats":{"anon":7000000,"inactive_file":2000000,\
    "active_file":500000}}}
    """
// cgroup v1: usage - total_inactive_file = 10_000_000 - 3_000_000. online_cpus が無いので percpu_usage の 2 個で数える.
// 使用率 = 100_000_000 / 1_000_000_000 * 2 = 0.2.
private let statsV1JSON = """
    {"cpu_stats":{"cpu_usage":{"total_usage":400000000,"percpu_usage":[200000000,200000000]},\
    "system_cpu_usage":2000000000},\
    "precpu_stats":{"cpu_usage":{"total_usage":300000000},"system_cpu_usage":1000000000},\
    "memory_stats":{"usage":10000000,"stats":{"cache":4000000,"inactive_file":1000000,\
    "total_inactive_file":3000000}}}
    """
private let statsCacheOnlyJSON = #"{"memory_stats":{"usage":10000000,"stats":{"cache":4000000}}}"#
private let statsJustStartedJSON = """
    {"cpu_stats":{"cpu_usage":{"total_usage":400000000},"system_cpu_usage":2000000000,"online_cpus":4},\
    "precpu_stats":{"cpu_usage":{"total_usage":0}},"memory_stats":{"usage":5000000}}
    """
private let statsNoMemoryJSON = #"{"read":"0001-01-01T00:00:00Z","memory_stats":{}}"#

private func listJSON() -> String {
    func entry(_ id: String, project: String?) -> String {
        let labels = project.map { #"{"com.docker.compose.project":"\#($0)","other":"x"}"# } ?? "{}"
        return #"{"Id":"\#(id)","Names":["/\#(id)"],"Image":"img","State":"running","Status":"Up","Labels":\#(labels)}"#
    }
    return "["
        + [
            entry("shop-web", project: "shop"), entry("shop-db", project: "shop"), entry("blog-web", project: "blog"),
            entry("lone", project: nil),
        ].joined(separator: ",") + "]"
}

private func withServer(
    routes: [String: TLSTestResponse],
    _ body: (DockerClient, RequestLog) async throws -> Void
) async throws {
    let credentials = try await makeTestCredentials()
    let log = RequestLog()
    let server = try await TLSTestServer.start(credentials: credentials, routes: routes, log: log)
    defer { server.stop() }
    try await body(DockerClient(hostPort: server.port, credentials: credentials), log)
}

private func respond(_ status: Int, _ body: String = "") -> TLSTestResponse {
    TLSTestResponse(status: status, body: body)
}

private func statsPath(_ id: String) -> String {
    "/containers/\(id)/stats?stream=false"
}

@Test(.timeLimit(.minutes(1)))
func containerUsageComputesCPUAndMemoryForCgroupV2() async throws {
    try await withServer(routes: [statsPath("c1"): respond(200, statsV2JSON)]) { client, log in
        let usage = try await client.containerUsage(id: "c1")

        let value = try #require(usage)
        #expect(abs(value.cpuUsage - 0.4) < 1e-9)
        #expect(value.memoryBytes == 8_000_000)
        #expect(await log.requests == [RecordedRequest(method: "GET", path: statsPath("c1"), body: "")])
    }
}

@Test(.timeLimit(.minutes(1)))
func containerUsageUsesTotalInactiveFileAndPerCPUCountForCgroupV1() async throws {
    try await withServer(routes: [statsPath("c1"): respond(200, statsV1JSON)]) { client, _ in
        let usage = try await client.containerUsage(id: "c1")
        let value = try #require(usage)

        #expect(abs(value.cpuUsage - 0.2) < 1e-9)
        #expect(value.memoryBytes == 7_000_000)
    }
}

@Test(.timeLimit(.minutes(1)))
func containerUsageFallsBackToCacheAndZeroCPUWithoutCPUStats() async throws {
    try await withServer(routes: [statsPath("c1"): respond(200, statsCacheOnlyJSON)]) { client, _ in
        let usage = try await client.containerUsage(id: "c1")
        let value = try #require(usage)

        #expect(value.cpuUsage == 0)
        #expect(value.memoryBytes == 6_000_000)
    }
}

@Test(.timeLimit(.minutes(1)))
func containerUsageTreatsEmptyPreviousSampleAsZeroCPU() async throws {
    try await withServer(routes: [statsPath("c1"): respond(200, statsJustStartedJSON)]) { client, _ in
        let usage = try await client.containerUsage(id: "c1")
        let value = try #require(usage)

        #expect(value.cpuUsage == 0)
        #expect(value.memoryBytes == 5_000_000)
    }
}

@Test(.timeLimit(.minutes(1)))
func containerUsageIsNilWithoutMemoryUsage() async throws {
    try await withServer(routes: [statsPath("c1"): respond(200, statsNoMemoryJSON)]) { client, _ in
        let usage = try await client.containerUsage(id: "c1")

        #expect(usage == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func containerUsageIsNilForMissingContainer() async throws {
    try await withServer(routes: [statsPath("c1"): respond(404)]) { client, _ in
        let usage = try await client.containerUsage(id: "c1")

        #expect(usage == nil)
    }
}

@Test(.timeLimit(.minutes(1)))
func containerUsageRejectsMalformedBodyAndErrorStatus() async throws {
    let routes = [statsPath("bad"): respond(200, "not json"), statsPath("err"): respond(500)]
    try await withServer(routes: routes) { client, _ in
        await #expect(throws: DockerClient.ClientError.invalidResponse) { try await client.containerUsage(id: "bad") }
        await #expect(throws: DockerClient.ClientError.unexpectedStatus(500)) {
            try await client.containerUsage(id: "err")
        }
    }
}

@Test(.timeLimit(.minutes(1)))
func projectUsagesSumsContainersPerComposeProject() async throws {
    let routes = [
        "/containers/json": respond(200, listJSON()),
        statsPath("shop-web"): respond(200, statsV2JSON),
        statsPath("shop-db"): respond(200, statsV1JSON),
        statsPath("blog-web"): respond(200, statsJustStartedJSON),
    ]
    try await withServer(routes: routes) { client, log in
        let usages = try await client.projectUsages()

        #expect(Set(usages.keys) == ["shop", "blog"])
        let shop = try #require(usages["shop"])
        #expect(abs(shop.cpuUsage - 0.6) < 1e-9)
        #expect(shop.memoryBytes == 15_000_000)
        #expect(usages["blog"] == ContainerUsage(cpuUsage: 0, memoryBytes: 5_000_000))
        #expect(await log.requests.map(\.path).contains(statsPath("lone")) == false)
    }
}

@Test(.timeLimit(.minutes(1)))
func projectUsagesSkipsUnmeasurableAndVanishedContainers() async throws {
    let routes = [
        "/containers/json": respond(200, listJSON()),
        statsPath("shop-web"): respond(200, statsV2JSON),
        statsPath("shop-db"): respond(404),
        statsPath("blog-web"): respond(200, statsNoMemoryJSON),
    ]
    try await withServer(routes: routes) { client, _ in
        let usages = try await client.projectUsages()

        #expect(Set(usages.keys) == ["shop"])
        #expect(usages["shop"]?.memoryBytes == 8_000_000)
    }
}
