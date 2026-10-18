public enum RelayConnectionState: String, CaseIterable, Hashable, Sendable {
    case disconnected
    case connecting
    case connected
    case reconnecting
    case replaced
    case unauthorized
}
