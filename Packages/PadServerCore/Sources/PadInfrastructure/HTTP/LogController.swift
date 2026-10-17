import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadInterface

public struct LogController: Sendable {
    private let logBus: any LogBus

    public init(logBus: any LogBus) {
        self.logBus = logBus
    }

    public func addRoutes<Context: RequestContext>(to router: Router<Context>) {
        router.get("/v1/logs/stream") { _, _ in
            let entries = await logBus.subscribe()
            return Response(
                status: .ok,
                headers: [.contentType: "application/x-ndjson"],
                body: ResponseBody { writer in
                    let encoder = AdminAPIJSON.makeEncoder()
                    for await entry in entries {
                        var line = try encoder.encode(entry)
                        line.append(UInt8(ascii: "\n"))
                        try await writer.write(ByteBuffer(bytes: line))
                    }
                    try await writer.finish(nil)
                }
            )
        }
    }
}
