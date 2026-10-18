import PadDomain
import Testing

@testable import PadInterface

private func reading(_ state: GuestState, memory: Int? = 0, disk: Int? = 0) -> GuestStatusReading {
    GuestStatusReading(state: state, memoryBytes: memory, diskBytes: disk)
}

@Test func guestStatusShowsEveryGuestState() {
    #expect(GuestStatusPresenter.display(for: reading(.stopped)).state == "Stopped")
    #expect(GuestStatusPresenter.display(for: reading(.starting)).state == "Starting")
    #expect(GuestStatusPresenter.display(for: reading(.ready)).state == "Ready")
    #expect(GuestStatusPresenter.display(for: reading(.failed)).state == "Failed")
}

@Test func guestStatusShowsMemoryAndDiskInMegabytes() {
    let display = GuestStatusPresenter.display(
        for: reading(.ready, memory: 512 * 1_048_576, disk: 256 * 1_048_576))

    #expect(display == GuestStatusDisplay(state: "Ready", memory: "512 MB", disk: "256 MB"))
}

@Test func guestStatusShowsLargeValuesInGigabytes() {
    let display = GuestStatusPresenter.display(
        for: reading(.ready, memory: 3 * 1_073_741_824 / 2, disk: 64 * 1_073_741_824))

    #expect(display.memory == "1.5 GB")
    #expect(display.disk == "64 GB")
}

@Test func guestStatusShowsZeroUsage() {
    let display = GuestStatusPresenter.display(for: reading(.stopped))

    #expect(display == GuestStatusDisplay(state: "Stopped", memory: "0 MB", disk: "0 MB"))
}

@Test func guestStatusSwitchesToGigabytesAtOneGibibyte() {
    let below = GuestStatusPresenter.display(for: reading(.ready, memory: 1_073_741_823))
    let exact = GuestStatusPresenter.display(for: reading(.ready, memory: 1_073_741_824))

    #expect(below.memory == "1024 MB")
    #expect(exact.memory == "1 GB")
}

@Test func guestStatusShowsUnmeasuredForMissingValues() {
    let display = GuestStatusPresenter.display(for: reading(.starting, memory: nil, disk: nil))

    #expect(display == GuestStatusDisplay(state: "Starting", memory: "測れません", disk: "測れません"))
}

@Test func guestStatusShowsNoGuestForNilReading() {
    #expect(
        GuestStatusPresenter.display(for: nil)
            == GuestStatusDisplay(state: "No guest", memory: "測れません", disk: "測れません"))
}
