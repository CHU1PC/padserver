import CryptoKit
import Foundation
import PadApplication

struct ScannedFile: Equatable {
    let path: String
    let hash: BlobHash
    let url: URL
}

enum StaticSiteScannerError: Error, CustomStringConvertible, Equatable {
    case rootNotFound(String)

    var description: String {
        switch self {
        case .rootNotFound(let root):
            "The static site root '\(root)' is not a directory."
        }
    }
}

enum StaticSiteScanner {
    /// root 以下の通常ファイルを走査し, root からの相対 path と SHA-256 を返します. path の昇順です.
    static func scan(root: URL, fileManager: FileManager = .default) throws -> [ScannedFile] {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path(), isDirectory: &isDirectory), isDirectory.boolValue,
            let enumerator = fileManager.enumerator(atPath: root.path())
        else {
            throw StaticSiteScannerError.rootNotFound(root.lastPathComponent)
        }

        var files: [ScannedFile] = []
        for case let path as String in enumerator {
            let url = root.appending(path: path)
            guard try fileManager.attributesOfItem(atPath: url.path())[.type] as? FileAttributeType == .typeRegular
            else {
                continue
            }
            files.append(ScannedFile(path: path, hash: try hash(of: url), url: url))
        }
        return files.sorted { $0.path < $1.path }
    }

    // mappedIfSafe で読むため, 大きなファイルでも memory に全部は載らない.
    private static func hash(of url: URL) throws -> BlobHash {
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try BlobHash(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }
}
