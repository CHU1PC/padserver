import Foundation
import PadDomain
import Testing

@testable import PadInterface

private func usage(cpu: Double, memoryBytes: Int) throws -> ProjectUsage {
    try ProjectUsage(cpuUsage: cpu, memoryBytes: memoryBytes, measuredAt: Date(timeIntervalSince1970: 0))
}

@Test func presenterShowsCPUPercentAndMemoryInMegabytes() throws {
    let display = ProjectUsagePresenter.display(for: try usage(cpu: 0.255, memoryBytes: 256 * 1_048_576))

    #expect(display == ProjectUsageDisplay(cpu: "25.5%", memory: "256 MB"))
}

@Test func presenterShowsCPUAboveOneCoreAsIs() throws {
    let display = ProjectUsagePresenter.display(for: try usage(cpu: 2.5, memoryBytes: 1_048_576))

    #expect(display.cpu == "250%")
}

@Test func presenterShowsOneCoreAsHundredPercent() throws {
    #expect(ProjectUsagePresenter.display(for: try usage(cpu: 1.0, memoryBytes: 0)).cpu == "100%")
}

@Test func presenterShowsZeroUsage() throws {
    let display = ProjectUsagePresenter.display(for: try usage(cpu: 0, memoryBytes: 0))

    #expect(display == ProjectUsageDisplay(cpu: "0%", memory: "0 MB"))
}

@Test func presenterShowsLargeMemoryInGigabytes() throws {
    let display = ProjectUsagePresenter.display(for: try usage(cpu: 0, memoryBytes: 3 * 1_073_741_824 / 2))

    #expect(display.memory == "1.5 GB")
}

@Test func presenterSwitchesToGigabytesAtOneGibibyte() throws {
    let below = ProjectUsagePresenter.display(for: try usage(cpu: 0, memoryBytes: 1_073_741_823))
    let exact = ProjectUsagePresenter.display(for: try usage(cpu: 0, memoryBytes: 1_073_741_824))

    #expect(below.memory == "1024 MB")
    #expect(exact.memory == "1 GB")
}

@Test func presenterShowsUnmeasuredForNilUsage() {
    #expect(
        ProjectUsagePresenter.display(for: nil)
            == ProjectUsageDisplay(cpu: "測れません", memory: "測れません"))
}
