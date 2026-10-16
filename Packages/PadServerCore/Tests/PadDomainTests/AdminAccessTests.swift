import Testing

@testable import PadDomain

@Test func adminTokenDescriptionsRedactSensitiveValues() {
    let token = AdminToken(String(repeating: "x", count: 32))
    #expect(String(describing: token) == "AdminToken(<redacted>)")
    #expect(String(reflecting: token) == "AdminToken(<redacted>)")
}

@Test(arguments: ["100.64.0.0", "100.127.255.255"])
func clientAddressAcceptsIPv4TailnetBoundaries(value: String) {
    #expect(ClientAddress(value).isInTailnet)
}

@Test(arguments: ["100.63.255.255", "100.128.0.0", "99.64.0.0", "101.64.0.0"])
func clientAddressRejectsIPv4OutsideTailnet(value: String) {
    #expect(!ClientAddress(value).isInTailnet)
}

@Test(arguments: [
    "fd7a:115c:a1e0::",
    "fd7a:115c:a1e0:ffff:ffff:ffff:ffff:ffff",
    "fd7a:115c:a1e0::100.64.0.1",
])
func clientAddressAcceptsIPv6TailnetBoundaries(value: String) {
    #expect(ClientAddress(value).isInTailnet)
}

@Test(arguments: ["fd7a:115c:a1df:ffff:ffff:ffff:ffff:ffff", "fd7a:115c:a1e1::", "::1"])
func clientAddressRejectsIPv6OutsideTailnet(value: String) {
    #expect(!ClientAddress(value).isInTailnet)
}

@Test(arguments: [
    "not-an-address",
    "100.64.0.256",
    "fd7a:115c:a1e0:gggg::",
    "fd7a:115c:a1e0:100.64.0.1::",
    "fd7a:115c:a1e0:100.64.0.1::1",
    "fd7a:115c:a1e0:100.64.0.1::ffff",
])
func clientAddressRejectsMalformedAddress(value: String) {
    #expect(!ClientAddress(value).isInTailnet)
}
