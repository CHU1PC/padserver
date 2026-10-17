import Foundation
import Hummingbird
import PadApplication
import PadDomain

public struct RequestLogMiddleware: RouterMiddleware {
    private static let millisecondsPerSecond = 1_000.0
    private static let attosecondsPerMillisecond = 1_000_000_000_000_000.0

    private let logBus: any LogBus

    public init(logBus: any LogBus) {
        self.logBus = logBus
    }

    public func handle(
        _ request: Request, context: BasicRequestContext,
        next: (Request, BasicRequestContext) async throws -> Response
    ) async throws -> Response {
        let timestamp = Date()
        let started = ContinuousClock.now
        do {
            let response = try await next(request, context)
            await publish(request: request, status: response.status.code, timestamp: timestamp, started: started)
            return response
        } catch {
            await publish(
                request: request, status: HTTPResponse.Status.internalServerError.code,
                timestamp: timestamp, started: started)
            throw error
        }
    }

    private func publish(request: Request, status: Int, timestamp: Date, started: ContinuousClock.Instant) async {
        let elapsed = started.duration(to: .now)
        let milliseconds =
            Double(elapsed.components.seconds) * Self.millisecondsPerSecond
            + Double(elapsed.components.attoseconds) / Self.attosecondsPerMillisecond
        let host = request.head.authority ?? "-"
        let message = "host=\(host) path=\(request.uri.path) status=\(status) duration_ms=\(milliseconds)"
        await logBus.publish(LogEntry(timestamp: timestamp, source: "serving", level: .info, message: message))
    }
}
