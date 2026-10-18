import Foundation
import Testing

@testable import PadDomain

@Test func projectUsageKeepsCPUMemoryAndMeasuredTime() throws {
    let measuredAt = Date(timeIntervalSince1970: 1_700_000_000)
    let usage = try ProjectUsage(cpuUsage: 0.25, memoryBytes: 1_048_576, measuredAt: measuredAt)

    #expect(usage.cpuUsage == 0.25)
    #expect(usage.memoryBytes == 1_048_576)
    #expect(usage.measuredAt == measuredAt)
}

@Test func projectUsageAcceptsZeroBoundaries() throws {
    let usage = try ProjectUsage(cpuUsage: 0, memoryBytes: 0, measuredAt: Date(timeIntervalSince1970: 0))

    #expect(usage.cpuUsage == 0)
    #expect(usage.memoryBytes == 0)
}

@Test(arguments: [-0.1, -Double.infinity, Double.infinity, Double.nan])
func projectUsageRejectsInvalidCPUUsage(cpuUsage: Double) {
    #expect(throws: ProjectUsage.ValidationError.invalidCPUUsage) {
        try ProjectUsage(cpuUsage: cpuUsage, memoryBytes: 0, measuredAt: Date(timeIntervalSince1970: 0))
    }
}

@Test func projectUsageRejectsNegativeMemoryBytes() {
    #expect(throws: ProjectUsage.ValidationError.invalidMemoryBytes) {
        try ProjectUsage(cpuUsage: 0, memoryBytes: -1, measuredAt: Date(timeIntervalSince1970: 0))
    }
}
