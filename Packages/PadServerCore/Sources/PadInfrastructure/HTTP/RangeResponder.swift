import Foundation
import HummingbirdCore
import HTTPTypes
import PadApplication

public struct RangeResponder: Sendable {
    private static let rangePartsCount = 2

    private enum Selection {
        case full
        case partial(start: Int64, end: Int64)
        case unsatisfiable
    }

    public init() {
        // 状態を持たない応答器を公開 API から作れるようにします。
    }

    public func respond(to request: Request, stream: BlobBodyStream, size: Int64) -> Response {
        var headers = HTTPFields()
        switch Self.selectRange(request.headers[.range], size: size) {
        case .full:
            headers[.contentLength] = String(size)
            return Response(status: .ok, headers: headers, body: body(stream, start: 0, end: size - 1))

        case .partial(let start, let end):
            headers[.contentRange] = "bytes \(start)-\(end)/\(size)"
            headers[.contentLength] = String(end - start + 1)
            return Response(status: .partialContent, headers: headers, body: body(stream, start: start, end: end))

        case .unsatisfiable:
            headers[.contentRange] = "bytes */\(size)"
            return Response(status: .rangeNotSatisfiable, headers: headers)
        }
    }

    private static func selectRange(_ header: String?, size: Int64) -> Selection {
        guard let header, header.hasPrefix("bytes=") else { return .full }
        let value = header.dropFirst("bytes=".count)
        guard !value.contains(",") else { return .full }
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == rangePartsCount else { return .full }

        if !parts[0].isEmpty {
            return selectLeadingRange(start: parts[0], end: parts[1], size: size)
        }
        return selectSuffixRange(parts[1], size: size)
    }

    private static func selectLeadingRange(start text: Substring, end: Substring, size: Int64) -> Selection {
        guard let start = Int64(text), start >= 0 else { return .full }
        let requestedEnd: Int64
        if end.isEmpty {
            requestedEnd = size - 1
        } else {
            guard let end = Int64(end), end >= start else { return .full }
            requestedEnd = end
        }
        guard start < size else { return .unsatisfiable }
        return .partial(start: start, end: min(requestedEnd, size - 1))
    }

    private static func selectSuffixRange(_ text: Substring, size: Int64) -> Selection {
        guard let suffixLength = Int64(text), suffixLength >= 0 else { return .full }
        guard suffixLength > 0 else { return .unsatisfiable }
        guard size > 0 else { return .full }
        return .partial(start: max(0, size - suffixLength), end: size - 1)
    }

    private func body(_ stream: BlobBodyStream, start: Int64, end: Int64) -> ResponseBody {
        ResponseBody(contentLength: Int(max(0, end - start + 1))) { writer in
            var offset: Int64 = 0
            for try await chunk in stream {
                let nextOffset = offset + Int64(chunk.count)
                let lower = max(start, offset)
                let upper = min(end + 1, nextOffset)
                if lower < upper {
                    let localStart = Int(lower - offset)
                    let count = Int(upper - lower)
                    try await writer.write(.init(bytes: chunk.dropFirst(localStart).prefix(count)))
                }
                offset = nextOffset
                if offset > end { break }
            }
            try await writer.finish(nil)
        }
    }
}
