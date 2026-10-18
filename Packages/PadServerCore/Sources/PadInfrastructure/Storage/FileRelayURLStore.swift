import Foundation
import PadApplication

public actor FileRelayURLStore: RelayURLStore {
    private let fileURL: URL

    public init(directory: URL) {
        fileURL = directory.appendingPathComponent("relay-url.txt")
    }

    public func relayURL() throws -> URL? {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        guard let text = String(data: data, encoding: .utf8), let url = URL(string: text) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return url
    }

    public func setRelayURL(_ url: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try Data(url.absoluteString.utf8).write(to: fileURL, options: .atomic)
    }
}
