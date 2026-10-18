import PadDomain

public protocol UsageSource: Sendable {
    /// プロジェクトの現在の使用量を返します。測れないプロジェクトは nil を返します。
    func usage(of project: ProjectName) async throws -> ProjectUsage?
}
