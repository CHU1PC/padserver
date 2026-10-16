import Foundation
import Testing

@testable import PadDomain

private let testShareLinkID: UUID = {
    guard let id = UUID(uuidString: "00000000-0000-0000-0000-00000000002a") else {
        fatalError("Invalid test UUID")
    }
    return id
}()

@Test func shareLinkKeepsProvidedID() {
    let id = testShareLinkID
    let shareLink = ShareLink(id: id, expiresAt: Date(timeIntervalSince1970: 1_000))

    #expect(shareLink.id == id)
}

@Test func shareLinkIsValidBeforeExpiration() {
    let expiresAt = Date(timeIntervalSince1970: 1_000)
    let shareLink = ShareLink(id: testShareLinkID, expiresAt: expiresAt)

    #expect(shareLink.isValid(at: Date(timeIntervalSince1970: 999)))
}

@Test func shareLinkIsInvalidAtExpiration() {
    let expiresAt = Date(timeIntervalSince1970: 1_000)
    let shareLink = ShareLink(id: testShareLinkID, expiresAt: expiresAt)

    #expect(!shareLink.isValid(at: expiresAt))
}

@Test func shareLinkIsInvalidAfterExpiration() {
    let expiresAt = Date(timeIntervalSince1970: 1_000)
    let shareLink = ShareLink(id: testShareLinkID, expiresAt: expiresAt)

    #expect(!shareLink.isValid(at: Date(timeIntervalSince1970: 1_001)))
}
