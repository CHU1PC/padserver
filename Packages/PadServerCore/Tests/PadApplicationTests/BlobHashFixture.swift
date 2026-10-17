import CryptoKit
import Foundation
import PadApplication

func fixtureBlobHash(_ label: String) throws -> BlobHash {
    try BlobHash(CryptoKit.SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined())
}
