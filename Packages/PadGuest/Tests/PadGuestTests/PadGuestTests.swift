import PadGuest
import Testing

@Test func packageNamespaceIsAvailableToConsumers() {
    let namespace: PadGuest.Type = PadGuest.self
    #expect(String(describing: namespace) == "PadGuest")
}
