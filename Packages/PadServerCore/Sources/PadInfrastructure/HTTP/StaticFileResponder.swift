import Foundation
import Hummingbird
import PadApplication
import PadDomain

public struct StaticFileResponder: Sendable {
    private let storage: any ProjectStorage

    public init(storage: any ProjectStorage) {
        self.storage = storage
    }

    public func respond(to request: Request, route: Route, context: BasicRequestContext) async throws -> Response {
        guard let path = relativePath(for: request.uri.path, prefix: route.pathPrefix.value) else {
            return Response(status: .notFound)
        }
        let releases = try await storage.listReleases()
        guard let release = releases.first(where: { $0.project == route.project && $0.state == .active }) else {
            return Response(status: .notFound)
        }
        let manifest = try await storage.releaseManifest(for: release.id)
        guard let file = manifest.files.first(where: { $0.path == path }),
            let stream = try await storage.openBlob(file.blob)
        else {
            return Response(status: .notFound)
        }

        let contentType =
            MediaType.getMediaType(forExtension: (path as NSString).pathExtension)?.description
            ?? MediaType.applicationBinary.description
        let eTag = "\"\(file.blob.value)\""
        return try await request.ifNoneMatch(
            headers: [.contentType: contentType], eTag: eTag, context: context
        ) {
            Response(
                status: .ok,
                body: ResponseBody { writer in
                    for try await chunk in stream {
                        try await writer.write(.init(bytes: chunk))
                    }
                    try await writer.finish(nil)
                })
        }
    }

    private func relativePath(for requestPath: String, prefix: String) -> String? {
        guard requestPath.hasPrefix(prefix) else { return nil }
        let suffix = String(requestPath.dropFirst(prefix == "/" ? 0 : prefix.count))
        guard suffix.isEmpty || suffix.hasPrefix("/") else { return nil }
        guard let decoded = suffix.removingPercentEncoding else { return nil }
        let path = decoded.hasPrefix("/") ? String(decoded.dropFirst()) : decoded
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains(where: { $0 == ".." || $0 == "." }),
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else {
            return nil
        }
        return path.isEmpty ? "index.html" : path
    }
}
