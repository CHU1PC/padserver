import Foundation
import PadApplication
import Testing

private let validHash = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

@Test func blobHashAcceptsLowercaseSHA256HexAndRoundTrips() throws {
    let hash = try BlobHash(validHash)
    #expect(hash.value == validHash)

    let data = try JSONEncoder().encode(hash)
    #expect(String(data: data, encoding: .utf8) == "\"\(validHash)\"")
    #expect(try JSONDecoder().decode(BlobHash.self, from: data) == hash)
}

@Test(arguments: [
    "",
    "abc123",
    String(repeating: "a", count: 63),
    String(repeating: "a", count: 65),
    String(repeating: "A", count: 64),
    String(repeating: "g", count: 64),
    "sha256-" + String(repeating: "a", count: 57),
    "../" + String(repeating: "a", count: 61),
    String(repeating: "a", count: 63) + "/",
    String(repeating: "a", count: 63) + "\n",
    String(repeating: "a", count: 63) + "\u{0661}",
])
func blobHashRejectsInvalidValuesOnInitAndDecode(value: String) throws {
    #expect(throws: BlobHash.ValidationError.invalidHash) {
        try BlobHash(value)
    }

    let data = try JSONEncoder().encode(value)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(BlobHash.self, from: data)
    }
}

@Test(arguments: [
    "index.html",
    "assets/app.js",
    "a/b/c/d.txt",
    "日本語/ファイル.html",
    "file with space.txt",
    ".well-known/security.txt",
    "a..b",
    "...",
])
func releaseManifestFileAcceptsRelativePathsAndRoundTrips(path: String) throws {
    let file = try ReleaseManifestFile(path: path, blob: BlobHash(validHash))
    #expect(file.path == path)

    let data = try JSONEncoder().encode(file)
    #expect(try JSONDecoder().decode(ReleaseManifestFile.self, from: data) == file)
}

@Test(arguments: [
    "",
    "/",
    "/etc/passwd",
    "..",
    "../secret",
    "a/../b",
    "a/..",
    ".",
    "./index.html",
    "a/./b",
    "a//b",
    "a/",
    "a\\b",
    "..\\secret",
    "a\u{0}b",
    "a\nb",
    "a\tb",
    "a\u{7F}b",
    "a\u{85}b",
])
func releaseManifestFileRejectsUnsafePathsOnInitAndDecode(path: String) throws {
    #expect(throws: ReleaseManifestFile.ValidationError.invalidPath) {
        try ReleaseManifestFile(path: path, blob: BlobHash(validHash))
    }

    let object: [String: String] = ["path": path, "blob": validHash]
    let data = try JSONEncoder().encode(object)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ReleaseManifestFile.self, from: data)
    }
}

@Test func releaseManifestDecodeRejectsInvalidHashInFile() throws {
    let json = #"{"files":[{"path":"index.html","blob":"abc123"}]}"#
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ReleaseManifest.self, from: Data(json.utf8))
    }
}
