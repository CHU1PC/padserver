import Darwin
import PadDomain

public struct AuthorizeAdmin: Sendable {
    private let secretStore: any SecretStore

    public init(secretStore: any SecretStore) {
        self.secretStore = secretStore
    }

    public func callAsFunction(token: AdminToken, address: ClientAddress) async throws -> Bool {
        guard address.isInTailnet, let expected = try await secretStore.adminToken() else {
            return false
        }
        return tokensMatch(token, expected)
    }

    private func tokensMatch(_ supplied: AdminToken, _ expected: AdminToken) -> Bool {
        var suppliedBytes = Array(supplied.value.utf8)
        var expectedBytes = Array(expected.value.utf8)
        let suppliedCount = suppliedBytes.count
        let expectedCount = expectedBytes.count
        // 空の token でも buffer の先頭が存在するよう、少なくとも1バイトを比較します。
        let comparisonCount = max(suppliedCount, expectedCount, 1)
        suppliedBytes.append(contentsOf: repeatElement(0, count: comparisonCount - suppliedCount))
        expectedBytes.append(contentsOf: repeatElement(0, count: comparisonCount - expectedCount))
        let contentsMatch = suppliedBytes.withUnsafeBufferPointer { suppliedBuffer in
            expectedBytes.withUnsafeBufferPointer { expectedBuffer in
                guard let suppliedBase = suppliedBuffer.baseAddress, let expectedBase = expectedBuffer.baseAddress
                else {
                    return false
                }
                return Darwin.timingsafe_bcmp(suppliedBase, expectedBase, comparisonCount) == 0
            }
        }
        return contentsMatch && suppliedCount == expectedCount
    }
}
