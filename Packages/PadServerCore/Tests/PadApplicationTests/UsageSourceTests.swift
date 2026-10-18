import Foundation
import PadApplication
import PadDomain
import PadTestSupport
import Testing

@Test func fixedUsageSourceReturnsUsageForMeasuredProjectAndNilOtherwise() async throws {
    let compose = try ProjectName("app")
    let staticSite = try ProjectName("blog")
    let usage = try ProjectUsage(
        cpuUsage: 0.5, memoryBytes: 2_048, measuredAt: Date(timeIntervalSince1970: 1_700_000_000))
    let source: any UsageSource = FixedUsageSource(usages: [compose: usage])

    #expect(try await source.usage(of: compose) == usage)
    #expect(try await source.usage(of: staticSite) == nil)
}
