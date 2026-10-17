import Foundation
import Testing

@testable import PadDomain

@Test(arguments: [
    (GuestState.stopped, "stopped"),
    (GuestState.starting, "starting"),
    (GuestState.ready, "ready"),
    (GuestState.failed, "failed"),
])
func guestStateJSONValuesAreStable(state: GuestState, wireValue: String) throws {
    let data = Data("\"\(wireValue)\"".utf8)
    #expect(try JSONEncoder().encode(state) == data)
    #expect(try JSONDecoder().decode(GuestState.self, from: data) == state)
}
