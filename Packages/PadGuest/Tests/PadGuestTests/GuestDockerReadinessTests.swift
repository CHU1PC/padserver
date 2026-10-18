@testable import PadGuest
import Testing

private enum Constants {
    static let guestPort: UInt16 = 2376
    static let hostPort: UInt16 = 49152
}

private struct ProbeFailure: Error {}

private actor Recorder {
    private(set) var opened: [UInt16] = []
    private(set) var probed: [UInt16] = []
    private(set) var made = 0

    func open(_ guestPort: UInt16) { opened.append(guestPort) }
    func probe(_ hostPort: UInt16) { probed.append(hostPort) }
    func make() { made += 1 }
}

private func makeReadiness(
    recorder: Recorder, openFails: Bool = false, probeFails: Bool = false, makeFails: Bool = false
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
