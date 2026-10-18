import Foundation
import PadInfrastructure
import Testing

private struct VectorRepeat: Decodable, Sendable {
    let byteHex: String
    let count: Int
}

private struct VectorPayload: Decodable, Sendable {
    let utf8: String?
    let hex: String?
    let ackBytes: UInt32?
    let `repeat`: VectorRepeat?
}

private struct VectorFrame: Decodable, Sendable {
    let type: String
    let id: UInt32
    let payload: VectorPayload
}

private struct ValidVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let frame: VectorFrame
    let hex: String?
    let headerHex: String?
    let totalLength: Int?
    let decodeOnly: Bool?

    var testDescription: String { name }
}

private struct InvalidPayload: Decodable, Sendable {
    let `repeat`: VectorRepeat
}

private struct InvalidExpect: Decodable, Sendable {
    let level: String
}

private struct InvalidVector: Decodable, Sendable, CustomTestStringConvertible {
    let name: String
    let hex: String?
    let headerHex: String?
    let payload: InvalidPayload?
    let expect: InvalidExpect

    var testDescription: String { name }
}

private struct ValidVectorFile: Decodable {
    let frames: [ValidVector]
}

private struct InvalidVectorFile: Decodable {
    let invalidFrames: [InvalidVector]
}

private let vectorsDirectory = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("relay/test-vectors")

private func loadVectors<File: Decodable>(_ type: File.Type, named name: String) -> File {
    do {
        let data = try Data(contentsOf: vectorsDirectory.appendingPathComponent(name))
        return try JSONDecoder().decode(type, from: data)
    } catch {
        fatalError("cannot load \(name): \(error)")
    }
}

private let validVectors = loadVectors(ValidVectorFile.self, named: "frames.json").frames
private let invalidVectors = loadVectors(InvalidVectorFile.self, named: "invalid-frames.json").invalidFrames

private let hexDigitsPerByte = 2
private let hexRadix = 16
private let headerLength = 5

private func bytes(hex: String) throws -> Data {
    var result = Data()
    var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: hexDigitsPerByte)
        result.append(try #require(UInt8(hex[index..<next], radix: hexRadix)))
        index = next
    }
    return result
}

private func repeated(byteHex: String, count: Int) throws -> Data {
    Data(repeating: try #require(try bytes(hex: byteHex).first), count: count)
}

private func wireBytes(of vector: ValidVector) throws -> Data {
    if let hex = vector.hex { return try bytes(hex: hex) }
    let header = try bytes(hex: try #require(vector.headerHex))
    let spec = try #require(vector.frame.payload.repeat)
    return header + (try repeated(byteHex: spec.byteHex, count: spec.count))
}

private func payloadBytes(of vector: ValidVector) throws -> Data {
    let payload = vector.frame.payload
    if let utf8 = payload.utf8 { return Data(utf8.utf8) }
    if let hex = payload.hex { return try bytes(hex: hex) }
    if let spec = payload.repeat { return try repeated(byteHex: spec.byteHex, count: spec.count) }
    return Data()
}

private func expectedFrame(for vector: ValidVector) throws -> RelayFrame {
    let id = vector.frame.id
    let json = Data(try wireBytes(of: vector).dropFirst(headerLength))
    switch vector.frame.type {
    case "ReqHead":
        return .reqHead(id: id, head: try JSONDecoder().decode(RelayRequestHead.self, from: json))

    case "ResHead":
        return .resHead(id: id, head: try JSONDecoder().decode(RelayResponseHead.self, from: json))

    default:
        return try expectedSimpleFrame(for: vector)
    }
}

private func expectedSimpleFrame(for vector: ValidVector) throws -> RelayFrame {
    let id = vector.frame.id
    switch vector.frame.type {
    case "ReqBody":
        return .reqBody(id: id, chunk: try payloadBytes(of: vector))

    case "ReqEnd":
        return .reqEnd(id: id)

    case "ResBody":
        return .resBody(id: id, chunk: try payloadBytes(of: vector))

    case "ResEnd":
        return .resEnd(id: id)

    case "Cancel":
        return .cancel(id: id)

    case "Ack":
        return .ack(id: id, receivedBytes: try #require(vector.frame.payload.ackBytes))

    default:
        throw VectorError.unknownType(vector.frame.type)
    }
}

private enum VectorError: Error {
    case unknownType(String)
}

@Test func relayFrameVectorsAreLoaded() {
    #expect(validVectors.count == 28)
    #expect(invalidVectors.count == 15)
}

@Test(arguments: validVectors)
private func relayFrameDecodesVector(_ vector: ValidVector) throws {
    let decoded = try RelayFrame.decode(wireBytes(of: vector))

    #expect(try decoded == expectedFrame(for: vector))
}

@Test(arguments: validVectors.filter { $0.decodeOnly != true })
private func relayFrameEncodesVectorToTheSameBytes(_ vector: ValidVector) throws {
    let frame = try expectedFrame(for: vector)

    let encoded = try frame.encode()

    #expect(try encoded == wireBytes(of: vector))
    #expect(try RelayFrame.decode(encoded) == frame)
}

@Test(arguments: invalidVectors)
private func relayFrameRejectsInvalidVector(_ vector: InvalidVector) throws {
    let input: Data
    if let hex = vector.hex {
        input = try bytes(hex: hex)
    } else {
        let spec = try #require(vector.payload?.repeat)
        input = try bytes(hex: try #require(vector.headerHex)) + repeated(byteHex: spec.byteHex, count: spec.count)
    }

    let error = #expect(throws: RelayFrameError.self) {
        try RelayFrame.decode(input)
    }

    #expect(error?.level.rawValue == vector.expect.level)
}
