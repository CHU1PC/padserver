import Foundation
import Testing

@testable import PadDomain

@Test func storedFileKeepsNameAndByteSize() throws {
    let file = StoredFile(name: "report.pdf", size: 1234)
    #expect(file.name == "report.pdf")
    #expect(file.size == 1234)
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    #expect(try encoder.encode(file) == Data("{\"name\":\"report.pdf\",\"size\":1234}".utf8))
}
