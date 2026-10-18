import PadApplication
import PadDomain

public struct FixedUsageSource: UsageSource {
    private let usages: [ProjectName: ProjectUsage]

    public init(usages: [ProjectName: ProjectUsage]) {
        self.usages = usages
    }

    public func usage(of project: ProjectName) -> ProjectUsage? {
        usages[project]
    }
}
