@testable import PadGuest
import Testing

private enum Constants {
    static let guestPort: UInt16 = 2376
    static let hostPort: UInt16 = 49152
    static let project = "blog"
    static let usageCPU = 0.5
    static let usageMemoryBytes = 1_024
    static let usage = ContainerUsage(cpuUsage: usageCPU, memoryBytes: usageMemoryBytes)
}

private struct ProbeFailure: Error {}

private actor Recorder {
    private(set) var opened: [UInt16] = []
    private(set) var probed: [UInt16] = []
    private(set) var made = 0
    private(set) var usagesMade: [UInt16] = []

    func open(_ guestPort: UInt16) { opened.append(guestPort) }
    func probe(_ hostPort: UInt16) { probed.append(hostPort) }
    func make() { made += 1 }
    func makeUsages(_ hostPort: UInt16) { usagesMade.append(hostPort) }
}

private func makeReadiness(
    recorder: Recorder, openFails: Bool = false, probeFails: Bool = false, makeFails: Bool = false,
    usagesFail: Bool = false
) -> GuestDockerReadiness {
    GuestDockerReadiness(
        guestPort: Constants.guestPort,
        openPort: { guestPort in
            await recorder.open(guestPort)
            if openFails { throw ProbeFailure() }
            return Constants.hostPort
        },
        makeProbe: { hostPort in
            await recorder.make()
            if makeFails { throw ProbeFailure() }
            return {
                await recorder.probe(hostPort)
                if probeFails { throw ProbeFailure() }
            }
        },
        makeUsages: { hostPort in
            await recorder.makeUsages(hostPort)
            return {
                if usagesFail { throw ProbeFailure() }
                return [Constants.project: Constants.usage]
            }
        })
}

@Test func dockerReadinessIsTrueWhenPingSucceeds() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder)

    #expect(await readiness.isReady())
    #expect(await recorder.opened == [Constants.guestPort])
    #expect(await recorder.probed == [Constants.hostPort])
}

@Test func dockerReadinessIsFalseWhenPingFails() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder, probeFails: true)

    #expect(await readiness.isReady() == false)
}

@Test func dockerReadinessIsFalseWhenForwardCannotBeOpened() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder, openFails: true)

    #expect(await readiness.isReady() == false)
    #expect(await readiness.isReady() == false)
    #expect(await recorder.opened.count == 2)
    #expect(await recorder.probed.isEmpty)
}

@Test func dockerReadinessIsFalseWhenProbeCannotBeMade() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder, makeFails: true)

    #expect(await readiness.isReady() == false)
}

@Test func dockerReadinessOpensForwardAndMakesProbeOnlyOnce() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder)

    _ = await readiness.isReady()
    _ = await readiness.isReady()

    #expect(await recorder.opened.count == 1)
    #expect(await recorder.made == 1)
    #expect(await recorder.probed.count == 2)
}

@Test func dockerReadinessReadsProjectUsagesThroughTheForwardedPort() async throws {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder)

    let usages = try await readiness.projectUsages()

    #expect(usages == [Constants.project: Constants.usage])
    #expect(await recorder.usagesMade == [Constants.hostPort])
}

@Test func dockerReadinessThrowsUsagesWhenForwardCannotBeOpened() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder, openFails: true)

    await #expect(throws: ProbeFailure.self) { try await readiness.projectUsages() }
}

@Test func dockerReadinessThrowsUsagesWhenReadingFails() async {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder, usagesFail: true)

    await #expect(throws: ProbeFailure.self) { try await readiness.projectUsages() }
}

@Test func dockerReadinessSharesOneForwardBetweenProbeAndUsages() async throws {
    let recorder = Recorder()
    let readiness = makeReadiness(recorder: recorder)

    _ = await readiness.isReady()
    _ = try await readiness.projectUsages()
    _ = try await readiness.projectUsages()

    #expect(await recorder.opened.count == 1)
    #expect(await recorder.usagesMade.count == 1)
}
