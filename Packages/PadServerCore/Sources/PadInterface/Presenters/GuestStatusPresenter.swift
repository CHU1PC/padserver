import Foundation
import PadDomain

public struct GuestStatusReading: Hashable, Sendable {
    public let state: GuestState
    public let memoryBytes: Int?
    public let diskBytes: Int?

    public init(state: GuestState, memoryBytes: Int?, diskBytes: Int?) {
        self.state = state
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
    }
}

public struct GuestStatusDisplay: Hashable, Sendable {
    public let state: String
    public let memory: String
    public let disk: String

    public init(state: String, memory: String, disk: String) {
        self.state = state
        self.memory = memory
        self.disk = disk
    }
}

public enum GuestStatusPresenter {
    private static let unmeasured = "測れません"
    private static let noGuest = "No guest"
    private static let zeroFraction = ".0"
    private static let bytesPerMegabyte = 1_048_576.0
    private static let bytesPerGigabyte = 1_073_741_824.0

    /// guest の読み取り結果を、画面に出す文字列へ変換します。nil は guest が無い状態です。
    public static func display(for reading: GuestStatusReading?) -> GuestStatusDisplay {
        guard let reading else {
            return GuestStatusDisplay(state: noGuest, memory: unmeasured, disk: unmeasured)
        }
        return GuestStatusDisplay(
            state: stateLabel(reading.state),
            memory: sizeLabel(bytes: reading.memoryBytes),
            disk: sizeLabel(bytes: reading.diskBytes))
    }

    private static func stateLabel(_ state: GuestState) -> String {
        switch state {
        case .stopped: "Stopped"
        case .starting: "Starting"
        case .ready: "Ready"
        case .failed: "Failed"
        }
    }

    private static func sizeLabel(bytes: Int?) -> String {
        guard let bytes else { return unmeasured }
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
