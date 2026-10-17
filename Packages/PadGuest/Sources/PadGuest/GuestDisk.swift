import Foundation

@available(macOS 10.15, iOS 13, *)
public struct GuestDisk {
    private let applicationSupportURL: URL

    public init(applicationSupportURL: URL = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    )[0]) {
        self.applicationSupportURL = applicationSupportURL
    }

    public func createIfNeeded(sizeBytes: UInt64) throws -> URL {
        var directoryURL = applicationSupportURL.appendingPathComponent("PadServer/GuestDisk", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try directoryURL.setResourceValues(resourceValues)

        let diskURL = directoryURL.appendingPathComponent("guest.raw")
        if FileManager.default.fileExists(atPath: diskURL.path) {
            return diskURL
        }

        try Data().write(to: diskURL, options: .withoutOverwriting)
        do {
            let file = try FileHandle(forWritingTo: diskURL)
            try file.truncate(atOffset: sizeBytes)
            try file.close()
        } catch {
            try? FileManager.default.removeItem(at: diskURL)
            throw error
        }
        return diskURL
    }
}
