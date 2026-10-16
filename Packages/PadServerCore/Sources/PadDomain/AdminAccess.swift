public struct AdminToken: CustomDebugStringConvertible, CustomStringConvertible, Sendable {
    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var description: String {
        "AdminToken(<redacted>)"
    }

    public var debugDescription: String {
        description
    }
}

public struct ClientAddress: Hashable, Sendable {
    // 数値はIPの規定長、ASCIIの数字範囲、およびTailnetの割り当てプレフィックスを示す。
    private enum AddressConstants {
        static let tailnetIPv4FirstOctet: UInt8 = 100
        static let tailnetIPv4SecondOctetRange: ClosedRange<UInt8> = 64...127
        static let tailnetIPv6PrefixFirstWord: UInt16 = 0xfd7a
        static let tailnetIPv6PrefixSecondWord: UInt16 = 0x115c
        static let tailnetIPv6PrefixThirdWord: UInt16 = 0xa1e0
        static let ipv4OctetCount = 4
        static let ipv4FirstOctetIndex = 0
        static let ipv4SecondOctetIndex = 1
        static let ipv4ThirdOctetIndex = 2
        static let ipv4FourthOctetIndex = 3
        static let ipv4WordHighByteShift = 8
        static let ipv6WordCount = 8
        static let ipv6FirstWordIndex = 0
        static let ipv6SecondWordIndex = 1
        static let ipv6ThirdWordIndex = 2
        static let ipv6GroupCharacterLimit = 4
        static let ipv6CompressedHalfCount = 2
        static let hexadecimalRadix = 16
        static let decimalDigitASCII: ClosedRange<UInt8> = 48...57
        static let uppercaseHexLetterASCII: ClosedRange<UInt8> = 65...70
        static let lowercaseHexLetterASCII: ClosedRange<UInt8> = 97...102
    }

    public let value: String

    public init(_ value: String) {
        self.value = value
    }

    public var isInTailnet: Bool {
        if let address = Self.ipv4Bytes(value) {
            return address[AddressConstants.ipv4FirstOctetIndex] == AddressConstants.tailnetIPv4FirstOctet
                && AddressConstants.tailnetIPv4SecondOctetRange.contains(
                    address[AddressConstants.ipv4SecondOctetIndex]
                )
        }

        guard let address = Self.ipv6Words(value) else {
            return false
        }
        return address[AddressConstants.ipv6FirstWordIndex] == AddressConstants.tailnetIPv6PrefixFirstWord
            && address[AddressConstants.ipv6SecondWordIndex] == AddressConstants.tailnetIPv6PrefixSecondWord
            && address[AddressConstants.ipv6ThirdWordIndex] == AddressConstants.tailnetIPv6PrefixThirdWord
    }

    private static func ipv4Bytes(_ value: String) -> [UInt8]? {
        let components = value.split(separator: ".", omittingEmptySubsequences: false)
        guard components.count == AddressConstants.ipv4OctetCount else {
            return nil
        }

        var bytes: [UInt8] = []
        for component in components {
            guard !component.isEmpty,
                component.utf8.allSatisfy({ AddressConstants.decimalDigitASCII.contains($0) }),
                let byte = UInt8(component)
            else {
                return nil
            }
            bytes.append(byte)
        }
        return bytes
    }

    private static func ipv6Words(_ value: String) -> [UInt16]? {
        guard !value.isEmpty, !value.contains("%") else {
            return nil
        }

        let halves = value.components(separatedBy: "::")
        guard halves.count <= AddressConstants.ipv6CompressedHalfCount else {
            return nil
        }
        if halves.count > 1, halves[0].contains(".") {
            return nil
        }

        let left = ipv6Part(halves[0])
        guard let left else {
            return nil
        }

        if halves.count == 1 {
            guard left.count == AddressConstants.ipv6WordCount else {
                return nil
            }
            return left
        }

        let right = ipv6Part(halves[1])
        guard let right else {
            return nil
        }
        let uncompressedCount = left.count + right.count
        guard uncompressedCount < AddressConstants.ipv6WordCount else {
            return nil
        }
        return left + Array(repeating: 0, count: AddressConstants.ipv6WordCount - uncompressedCount) + right
    }

    private static func ipv6Part(_ value: String) -> [UInt16]? {
        guard !value.isEmpty else {
            return []
        }

        let groups = value.split(separator: ":", omittingEmptySubsequences: false)
        guard groups.allSatisfy({ !$0.isEmpty }) else {
            return nil
        }

        var words: [UInt16] = []
        for (index, group) in groups.enumerated() {
            if group.contains(".") {
                guard index == groups.count - 1, let embeddedWords = ipv4Words(String(group)) else {
                    return nil
                }
                words.append(contentsOf: embeddedWords)
                continue
            }

            guard group.utf8.count <= AddressConstants.ipv6GroupCharacterLimit,
                group.utf8.allSatisfy({
                    AddressConstants.decimalDigitASCII.contains($0)
                        || AddressConstants.uppercaseHexLetterASCII.contains($0)
                        || AddressConstants.lowercaseHexLetterASCII.contains($0)
                }),
                let word = UInt16(group, radix: AddressConstants.hexadecimalRadix)
            else {
                return nil
            }
            words.append(word)
        }
        return words
    }

    private static func ipv4Words(_ value: String) -> [UInt16]? {
        guard let bytes = ipv4Bytes(value) else {
            return nil
        }
        return [
            UInt16(bytes[AddressConstants.ipv4FirstOctetIndex]) << AddressConstants.ipv4WordHighByteShift
                | UInt16(bytes[AddressConstants.ipv4SecondOctetIndex]),
            UInt16(bytes[AddressConstants.ipv4ThirdOctetIndex]) << AddressConstants.ipv4WordHighByteShift
                | UInt16(bytes[AddressConstants.ipv4FourthOctetIndex]),
        ]
    }
}
