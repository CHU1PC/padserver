import Foundation
import Testing

@testable import PadDomain

@Test func projectNameAcceptsDNSLabel() throws {
    let name = try ProjectName("my-site2")
    #expect(name.value == "my-site2")
}

@Test(arguments: ["a", String(repeating: "a", count: 63)])
func projectNameAcceptsBoundaryLengths(value: String) throws {
    #expect(try ProjectName(value).value == value)
}

@Test(arguments: ["", "-site", "site-", "MySite", "my_site", "site/name", "sité", String(repeating: "a", count: 64)])
func projectNameRejectsInvalidValues(value: String) {
    #expect(throws: ProjectName.ValidationError.self) {
        try ProjectName(value)
    }
}

@Test func projectNameRejectsInvalidDecodedValue() {
    let data = Data("\"Invalid_Name\"".utf8)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ProjectName.self, from: data)
    }
}

@Test func projectContainsNameAndKind() throws {
    let project = Project(name: try ProjectName("blog"), kind: .staticSite)
    #expect(project.name.value == "blog")
    #expect(project.kind == .staticSite)
    #expect(ProjectKind.compose != project.kind)
}

@Test func projectKindJSONValuesAreStable() throws {
    #expect(try JSONEncoder().encode(ProjectKind.staticSite) == Data("\"staticSite\"".utf8))
    #expect(try JSONEncoder().encode(ProjectKind.compose) == Data("\"compose\"".utf8))
}
