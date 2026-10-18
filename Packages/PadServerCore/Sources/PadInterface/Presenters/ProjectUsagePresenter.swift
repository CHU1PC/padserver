import Foundation
import PadDomain

public struct ProjectUsageDisplay: Hashable, Sendable {
    public let cpu: String
    public let memory: String

    public init(cpu: String, memory: String) {
        self.cpu = cpu
        self.memory = memory
    }
}

public enum ProjectUsagePresenter {
    private static let unmeasured = "測れません"
    private static let zeroFraction = ".0"
    private static let bytesPerMegabyte = 1_048_576.0
    private static let bytesPerGigabyte = 1_073_741_824.0

    /// 使用量を、画面に出す文字列へ変換します。nil は測れないプロジェクトです。
    public static func display(for usage: ProjectUsage?) -> ProjectUsageDisplay {
        guard let usage else {
            return ProjectUsageDisplay(cpu: unmeasured, memory: unmeasured)
        }
        return ProjectUsageDisplay(
            cpu: "\(trimmed(usage.cpuUsage * 100))%", memory: memoryLabel(bytes: usage.memoryBytes))
    }

    private static func memoryLabel(bytes: Int) -> String {
        let value = Double(bytes)
        if value >= bytesPerGigabyte {
            return "\(trimmed(value / bytesPerGigabyte)) GB"
        }
        return "\(trimmed(value / bytesPerMegabyte)) MB"
    }

    // 小数1桁で丸め、末尾の ".0" は省く.
    private static func trimmed(_ value: Double) -> String {
        let text = String(format: "%.1f", value)
        return text.hasSuffix(zeroFraction) ? String(text.dropLast(zeroFraction.count)) : text
    }
}
