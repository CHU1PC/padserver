import Foundation
import Synchronization

enum RelaySocketMessage: Sendable {
    case data(Data)
    case text(String)
}

enum RelaySocketError: Error, Equatable {
    case upgradeRejected(status: Int)
    case closed(code: Int?)
}

protocol RelaySocket: Sendable {
    func receive() async throws -> RelaySocketMessage
    func send(_ message: RelaySocketMessage) async throws
    func close(code: Int)
}

protocol RelaySocketConnecting: Sendable {
    func open(_ request: URLRequest) async throws -> any RelaySocket
}

struct URLSessionRelaySocketConnector: RelaySocketConnecting {
    func open(_ request: URLRequest) async throws -> any RelaySocket {
        let opener = SocketOpener()
        let session = URLSession(configuration: .ephemeral, delegate: opener, delegateQueue: nil)
        let task = session.webSocketTask(with: request)
        let socket = URLSessionRelaySocket(task: task, session: session)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                opener.install(continuation)
                task.resume()
            }
            return socket
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
    }
}

private final class SocketOpener: NSObject, URLSessionWebSocketDelegate, Sendable {
    private let pending = Mutex<CheckedContinuation<Void, any Error>?>(nil)

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        pending.withLock { $0 = continuation }
    }

    private func resume(_ result: Result<Void, any Error>) {
        let continuation = pending.withLock { state in
            defer { state = nil }
            return state
        }
        continuation?.resume(with: result)
    }

    func urlSession(
        _ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?
    ) {
        resume(.success(()))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let response = task.response as? HTTPURLResponse {
            resume(.failure(RelaySocketError.upgradeRejected(status: response.statusCode)))
        } else {
            resume(.failure(error ?? RelaySocketError.closed(code: nil)))
        }
    }
}

private final class URLSessionRelaySocket: RelaySocket, Sendable {
    private let task: URLSessionWebSocketTask
    private let session: URLSession

    init(task: URLSessionWebSocketTask, session: URLSession) {
        self.task = task
        self.session = session
    }

    func receive() async throws -> RelaySocketMessage {
        do {
            switch try await task.receive() {
            case .data(let data): return .data(data)
            case .string(let text): return .text(text)
            @unknown default: return .text("")
            }
        } catch {
            let code = task.closeCode.rawValue
            throw RelaySocketError.closed(code: code == URLSessionWebSocketTask.CloseCode.invalid.rawValue ? nil : code)
        }
    }

    func send(_ message: RelaySocketMessage) async throws {
        switch message {
        case .data(let data): try await task.send(.data(data))
        case .text(let text): try await task.send(.string(text))
        }
    }

    func close(code: Int) {
        task.cancel(with: URLSessionWebSocketTask.CloseCode(rawValue: code) ?? .normalClosure, reason: nil)
        session.finishTasksAndInvalidate()
    }
}
