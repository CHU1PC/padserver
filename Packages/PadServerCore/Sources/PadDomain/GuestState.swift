public enum GuestState: String, Codable, Hashable, Sendable {
    case stopped
    case starting
    case ready
    case failed
}
