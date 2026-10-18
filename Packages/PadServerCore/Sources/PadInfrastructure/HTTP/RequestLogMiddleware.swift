import Foundation
import Hummingbird
import PadApplication
import PadDomain
import Synchronization

// handler が決めたプロジェクトの名前を middleware へ渡す、要求ごとの入れ物です。
final class RequestLogProject: Sendable {
    private let name = Mutex<ProjectName?>(nil)

    var value: ProjectName? { name.withLock { $0 } }

    func set(_ project: ProjectName) {
        name.withLock { $0 = project }
    }
}

public struct RequestLogMiddleware: Sendable {
    private static let millisecondsPerSecond = 1_000.0
    private static let attosecondsPerMillisecond = 1_000_000_000_000_000.0

    private let logBus: any LogBus

    public init(logBus: any LogBus) {
        self.logBus = logBus
    }

    func handle(
        _ request: Request, context: BasicRequestContext,
        next: (Request, BasicRequestContext, RequestLogProject) async throws -> Response
    ) async throws -> Response {
        let timestamp = Date()
        let started = ContinuousClock.now
        let project = RequestLogProject()
        do {
            let response = try await next(request, context, project)
            await publish(
                request: request, status: response.status.code, project: project.value,
                timestamp: timestamp, started: started)
            return response
        } catch {
            await publish(
                request: request, status: HTTPResponse.Status.internalServerError.code, project: project.value,
                timestamp: timestamp, started: started)
            throw error
        }
    }

    private func publish(
        request: Request, status: Int, project: ProjectName?, timestamp: Date, started: ContinuousClock.Instant
    ) async {
        let elapsed = started.duration(to: .now)
        let milliseconds =
            Double(elapsed.components.seconds) * Self.millisecondsPerSecond
            + Double(elapsed.components.attoseconds) / Self.attosecondsPerMillisecond
        let host = request.head.authority ?? "-"
        let message = "host=\(host) path=\(request.uri.path) status=\(status) duration_ms=\(milliseconds)"
        await logBus.publish(
            LogEntry(timestamp: timestamp, source: "serving", level: .info, message: message, project: project?.value))
    }
}
