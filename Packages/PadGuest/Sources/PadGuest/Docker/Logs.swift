import Foundation

public enum LogStream: Equatable, Sendable {
    case stdout
    case stderr
}

public struct LogChunk: Equatable, Sendable {
    public let stream: LogStream
    public let data: Data
}

/// 多重化された stream (8 バイトのヘッダと本文の繰り返し) を, 届いた分ずつ frame に分ける.
struct LogFrameParser {
    private enum Constants {
        static let headerLength = 8
        static let lengthOffset = 4
        static let byteBits = 8
        static let stdinType: UInt8 = 0
        static let stdoutType: UInt8 = 1
        static let stderrType: UInt8 = 2
        // Docker の frame は数 KiB だが, 壊れた長さで巨大な確保をしないよう 16 MiB で拒む
        static let maximumPayloadLength = 16_777_216
    }

    private var buffer = Data()

    mutating func append(_ data: Data) throws -> [LogChunk] {
        buffer.append(data)
        var chunks: [LogChunk] = []
        while buffer.count >= Constants.headerLength {
            let start = buffer.startIndex
            let stream = try Self.stream(for: buffer[start])
            let length = buffer[(start + Constants.lengthOffset)..<(start + Constants.headerLength)]
                .reduce(0) { $0 << Constants.byteBits | Int($1) }
            guard length <= Constants.maximumPayloadLength else { throw DockerClient.ClientError.invalidResponse }
            let end = start + Constants.headerLength + length
            guard buffer.count >= Constants.headerLength + length else { break }
            if length > 0 {
                chunks.append(LogChunk(stream: stream, data: Data(buffer[(start + Constants.headerLength)..<end])))
            }
            buffer = Data(buffer[end...])
        }
        return chunks
    }

    private static func stream(for type: UInt8) throws -> LogStream {
        switch type {
        // Docker の文書では stdin (0) の出力は stdout に書かれる
        case Constants.stdinType, Constants.stdoutType: return .stdout
        case Constants.stderrType: return .stderr
        default: throw DockerClient.ClientError.invalidResponse
        }
    }
}

@available(macOS 13, iOS 16, *)
extension DockerClient {
    private enum LogConstants {
        static let okStatus = 200
        static let notFoundStatus = 404
        static let rawFlushBytes = 4_096
        static let newline: UInt8 = 0x0A
    }

    /// 追尾を止めるには, 戻り値の stream を走査している Task を取り消す. 取り消すと接続を閉じる.
    /// `tty` は container を TTY 付きで作ったかどうか. TTY 付きの応答は多重化されず, すべて stdout として返す.
    public func followLogs(id: String, tty: Bool = false, tail: Int? = nil) -> AsyncThrowingStream<LogChunk, Error> {
        var query = ["follow", "stdout", "stderr"].map { URLQueryItem(name: $0, value: "1") }
        query.append(URLQueryItem(name: "timestamps", value: "0"))
        if let tail { query.append(URLQueryItem(name: "tail", value: String(tail))) }
        let path = "/containers/\(id)/logs"
        let (stream, continuation) = AsyncThrowingStream<LogChunk, Error>.makeStream()
        let task = Task {
            do {
                let (status, bytes) = try await sendStreaming(method: "GET", path: path, query: query)
                switch status {
                case LogConstants.okStatus: break
                case LogConstants.notFoundStatus: throw ContainerError.notFound
                default: throw ClientError.unexpectedStatus(status)
                }
                try await Self.forward(bytes, tty: tty, to: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error is CancellationError ? nil : error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func forward(
        _ bytes: URLSession.AsyncBytes, tty: Bool, to continuation: AsyncThrowingStream<LogChunk, Error>.Continuation
    ) async throws {
        var parser = LogFrameParser()
        var pending = Data()
        do {
            for try await byte in bytes {
                if tty {
                    pending.append(byte)
                    if byte == LogConstants.newline || pending.count >= LogConstants.rawFlushBytes {
                        continuation.yield(LogChunk(stream: .stdout, data: pending))
                        pending = Data()
                    }
                } else {
                    for chunk in try parser.append(Data([byte])) { continuation.yield(chunk) }
                }
            }
        } catch let error as ClientError {
            throw error
        } catch {
            if Task.isCancelled { throw CancellationError() }
            throw ClientError.connectionFailed
        }
        if !pending.isEmpty { continuation.yield(LogChunk(stream: .stdout, data: pending)) }
    }
}
