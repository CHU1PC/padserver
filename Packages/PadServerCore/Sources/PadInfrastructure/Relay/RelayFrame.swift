import Foundation

public enum RelayFrameType: UInt8, Sendable, CaseIterable {
    case reqHead = 1
    case reqBody = 2
    case reqEnd = 3
    case resHead = 4
    case resBody = 5
    case resEnd = 6
    case cancel = 7
    case ack = 8
}

public struct RelayHeader: Decodable, Equatable, Sendable {
    public let name: String
    public let value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        name = try container.decode(String.self)
        value = try container.decode(String.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "header must be a pair")
        }
    }
}

public struct RelayRequestHead: Decodable, Equatable, Sendable {
    public let method: String
    public let path: String
    public let host: String
    public let headers: [RelayHeader]
    public let hasBody: Bool

    public init(method: String, path: String, host: String, headers: [RelayHeader], hasBody: Bool) {
        self.method = method
        self.path = path
        self.host = host
        self.headers = headers
        self.hasBody = hasBody
    }
}

public struct RelayResponseHead: Decodable, Equatable, Sendable {
    public let status: Int
    public let headers: [RelayHeader]

    public init(status: Int, headers: [RelayHeader]) {
        self.status = status
        self.headers = headers
    }
}

public enum RelayFrameErrorLevel: String, Sendable {
    case decode
    case connection
    case request
}

public enum RelayFrameError: Error, Equatable, Sendable {
    case frameTooShort
    case unknownFrameType(UInt8)
    case invalidAckPayload
    case bodyChunkTooLarge
    case invalidHead

    public var level: RelayFrameErrorLevel {
        switch self {
        case .frameTooShort, .unknownFrameType: .decode
        case .invalidAckPayload, .bodyChunkTooLarge: .connection
        case .invalidHead: .request
        }
    }
}

public enum RelayFrame: Equatable, Sendable {
    case reqHead(id: UInt32, head: RelayRequestHead)
    case reqBody(id: UInt32, chunk: Data)
    case reqEnd(id: UInt32)
    case resHead(id: UInt32, head: RelayResponseHead)
    case resBody(id: UInt32, chunk: Data)
    case resEnd(id: UInt32)
    case cancel(id: UInt32)
    case ack(id: UInt32, receivedBytes: UInt32)

    private static let typeLength = 1
    private static let idLength = 4
    private static let headerLength = typeLength + idLength
    private static let ackPayloadLength = 4
    private static let bitsPerByte: UInt32 = 8
    private static let maxBodyChunkLength = 1_048_576
    private static let validStatusRange = 200...599

    public var id: UInt32 {
        switch self {
        case .reqHead(let id, _), .reqBody(let id, _), .reqEnd(let id), .resHead(let id, _), .resBody(let id, _),
            .resEnd(let id), .cancel(let id), .ack(let id, _):
            id
        }
    }

    public var type: RelayFrameType {
        switch self {
        case .reqHead: .reqHead
        case .reqBody: .reqBody
        case .reqEnd: .reqEnd
        case .resHead: .resHead
        case .resBody: .resBody
        case .resEnd: .resEnd
        case .cancel: .cancel
        case .ack: .ack
        }
    }

    public func encode() throws -> Data {
        var data = Data(capacity: Self.headerLength)
        data.append(type.rawValue)
        withUnsafeBytes(of: id.bigEndian) { data.append(contentsOf: $0) }
        switch self {
        case .reqHead(_, let head): data.append(try Self.json(head))
        case .resHead(_, let head): data.append(try Self.json(head))
        case .reqBody(_, let chunk), .resBody(_, let chunk): data.append(chunk)
        case .reqEnd, .resEnd, .cancel: break
        case .ack(_, let receivedBytes): withUnsafeBytes(of: receivedBytes.bigEndian) { data.append(contentsOf: $0) }
        }
        return data
    }

    public static func decode(_ data: Data) throws -> RelayFrame {
        guard data.count >= headerLength else { throw RelayFrameError.frameTooShort }
        let typeByte = data[data.startIndex]
        guard let type = RelayFrameType(rawValue: typeByte) else { throw RelayFrameError.unknownFrameType(typeByte) }
        let id = bigEndianInteger(data.dropFirst(typeLength).prefix(idLength))
        let payload = Data(data.dropFirst(headerLength))
        switch type {
        case .reqHead, .resHead:
            return try decodeHeadFrame(type, id: id, payload: payload)

        case .reqBody, .resBody:
            return try decodeBodyFrame(type, id: id, payload: payload)

        case .reqEnd:
            return .reqEnd(id: id)

        case .resEnd:
            return .resEnd(id: id)

        case .cancel:
            return .cancel(id: id)

        case .ack:
            return try decodeAck(id: id, payload: payload)
        }
    }

    private static func decodeHeadFrame(_ type: RelayFrameType, id: UInt32, payload: Data) throws -> RelayFrame {
        if type == .reqHead {
            let head = try decodeHead(RelayRequestHead.self, from: payload)
            guard head.path.hasPrefix("/") else { throw RelayFrameError.invalidHead }
            return .reqHead(id: id, head: head)
        }
        let head = try decodeHead(RelayResponseHead.self, from: payload)
        guard validStatusRange.contains(head.status) else { throw RelayFrameError.invalidHead }
        return .resHead(id: id, head: head)
    }

    private static func decodeBodyFrame(_ type: RelayFrameType, id: UInt32, payload: Data) throws -> RelayFrame {
        guard payload.count <= maxBodyChunkLength else { throw RelayFrameError.bodyChunkTooLarge }
        return type == .reqBody ? .reqBody(id: id, chunk: payload) : .resBody(id: id, chunk: payload)
    }

    private static func decodeAck(id: UInt32, payload: Data) throws -> RelayFrame {
        guard payload.count == ackPayloadLength else { throw RelayFrameError.invalidAckPayload }
        return .ack(id: id, receivedBytes: bigEndianInteger(payload))
    }

    private static func bigEndianInteger(_ bytes: some Sequence<UInt8>) -> UInt32 {
        bytes.reduce(0) { $0 << bitsPerByte | UInt32($1) }
    }

    private static let jsonEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return encoder
    }()

    // JSONEncoder は key の順を保証しないので, 見本と同じ並びで手で組む
    private static func json(_ head: RelayRequestHead) throws -> Data {
        let fields = [
            "\"method\":\(try literal(head.method))",
            "\"path\":\(try literal(head.path))",
            "\"host\":\(try literal(head.host))",
            "\"headers\":\(try literal(head.headers))",
            "\"hasBody\":\(head.hasBody)",
        ]
        return Data("{\(fields.joined(separator: ","))}".utf8)
    }

    private static func json(_ head: RelayResponseHead) throws -> Data {
        Data("{\"status\":\(head.status),\"headers\":\(try literal(head.headers))}".utf8)
    }

    private static func literal(_ headers: [RelayHeader]) throws -> String {
        let pairs = try headers.map { "[\(try literal($0.name)),\(try literal($0.value))]" }
        return "[\(pairs.joined(separator: ","))]"
    }

    private static func literal(_ string: String) throws -> String {
        guard let literal = String(bytes: try jsonEncoder.encode(string), encoding: .utf8) else {
            throw EncodingError.invalidValue(string, .init(codingPath: [], debugDescription: "not UTF-8"))
        }
        return literal
    }

    private static func decodeHead<Head: Decodable>(_ type: Head.Type, from payload: Data) throws -> Head {
        do {
            return try JSONDecoder().decode(type, from: payload)
        } catch {
            throw RelayFrameError.invalidHead
        }
    }
}
