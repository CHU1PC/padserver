import Foundation
import PadApplication
import PadDomain
import Testing

@testable import PadInterface

private func fixtures() throws -> (project: Project, release: Release) {
    let name = try ProjectName("example-site")
    let uuid = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001"))
    return (
        Project(name: name, kind: .staticSite),
        Release(id: ReleaseID(uuid), project: name, state: .active)
    )
}

private func expectJSON<T: Encodable>(_ value: T, matches example: String) throws {
    let actual = try JSONSerialization.jsonObject(with: AdminAPIJSON.makeEncoder().encode(value)) as? NSDictionary
    let expected = try JSONSerialization.jsonObject(with: Data(example.utf8)) as? NSDictionary
    #expect(actual == expected)
}

@Test func deploymentRequestAndDiffJSONMatchDocumentedExamples() throws {
    let example = """
        {
          "manifest": {
            "name": "example-site",
            "root": "dist",
            "routes": [{"host": "www.example.com", "path_prefix": "/"}]
          },
          "files": [{"path": "index.html", "hash": "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"}]
        }
        """
    let request = try AdminAPIJSON.makeDecoder().decode(AdminDeploymentRequest.self, from: Data(example.utf8))
    try expectJSON(request, matches: example)
    let hash = try BlobHash("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(request.files == [AdminDeploymentFile(path: "index.html", hash: hash)])

    let diff = AdminDeploymentDiffResponse(missingBlobs: request.files)
    try expectJSON(
        diff,
        matches: """
            {"missingBlobs":[{"path":"index.html","hash":"\(hash.value)"}]}
            """)
}

@Test func deploymentResponseJSONMatchesDocumentedExample() throws {
    let (project, release) = try fixtures()
    try expectJSON(
        AdminDeploymentResponse(project: project, release: release),
        matches: """
            {
              "project": {"name": "example-site", "kind": "staticSite"},
              "release": {
                "id": "00000000-0000-4000-8000-000000000001",
                "project": "example-site",
                "state": "active"
              }
            }
            """)
}

@Test func projectListJSONMatchesDocumentedExample() throws {
    let (project, release) = try fixtures()
    let status = AdminProjectStatus(project: project, activeRelease: release, running: true)
    try expectJSON(
        AdminProjectsResponse(projects: [status]),
        matches: """
            {
              "projects": [{
                "project": {"name": "example-site", "kind": "staticSite"},
                "activeRelease": {
                  "id": "00000000-0000-4000-8000-000000000001",
                  "project": "example-site",
                  "state": "active"
                },
                "running": true
              }]
            }
            """)
}

@Test func projectStopJSONMatchesDocumentedExample() throws {
    let (project, release) = try fixtures()
    try expectJSON(
        AdminProjectStatus(project: project, activeRelease: release, running: false),
        matches: """
            {
              "project": {"name": "example-site", "kind": "staticSite"},
              "activeRelease": {
                "id": "00000000-0000-4000-8000-000000000001",
                "project": "example-site",
                "state": "active"
              },
              "running": false
            }
            """)
}

@Test func projectStatusEncodesMissingReleaseAsNull() throws {
    let (project, _) = try fixtures()
    let withoutRelease = AdminProjectStatus(project: project, activeRelease: nil, running: false)
    try expectJSON(
        withoutRelease,
        matches: """
            {
              "project": {"name": "example-site", "kind": "staticSite"},
              "activeRelease": null,
              "running": false
            }
            """)
}

@Test func errorJSONMatchesDocumentedExampleAndCodes() throws {
    try expectJSON(
        AdminErrorResponse(error: AdminError(code: .projectNotFound, message: "Project was not found.")),
        matches: """
            {"error":{"code":"project_not_found","message":"Project was not found."}}
            """
    )
    let codes: [AdminErrorCode] = [
        .invalidRequest, .unauthorized, .forbidden, .projectNotFound,
        .deploymentIncomplete, .payloadTooLarge, .internalError, .fileNotFound, .shareLinkNotFound,
    ]
    let wireValues = [
        "invalid_request", "unauthorized", "forbidden", "project_not_found",
        "deployment_incomplete", "payload_too_large", "internal_error", "file_not_found", "share_link_not_found",
    ]
    for (code, wireValue) in zip(codes, wireValues) {
        #expect(try AdminAPIJSON.makeEncoder().encode(code) == Data("\"\(wireValue)\"".utf8))
    }
}

@Test func logEntryUsesUTCISO8601Timestamp() throws {
    let example = """
        {"timestamp":"2026-10-17T12:34:56Z","source":"web","level":"info","message":"Started"}
        """
    let entry = try AdminAPIJSON.makeDecoder().decode(LogEntry.self, from: Data(example.utf8))
    try expectJSON(entry, matches: example)
}

@Test func logEntryWithProjectAndServiceMatchesDocumentedExample() throws {
    let example = """
        {"timestamp":"2026-10-17T12:34:56Z","source":"serving","level":"info","message":"GET / 200",\
        "project":"blog","service":"web"}
        """
    let entry = try AdminAPIJSON.makeDecoder().decode(LogEntry.self, from: Data(example.utf8))
    try expectJSON(entry, matches: example)
    #expect(entry.project == "blog")
    #expect(entry.service == "web")
}

@Test func fileListJSONMatchesDocumentedExample() throws {
    let example = """
        {"files":[{"name":"report.pdf","size":1234}]}
        """
    let response = try AdminAPIJSON.makeDecoder().decode(AdminFilesResponse.self, from: Data(example.utf8))
    try expectJSON(response, matches: example)
    #expect(response.files == [StoredFile(name: "report.pdf", size: 1234)])
}

@Test func shareLinkRequestJSONMatchesDocumentedExample() throws {
    let example = """
        {"expiresAt":"2026-10-18T12:34:56Z"}
        """
    let request = try AdminAPIJSON.makeDecoder().decode(AdminShareLinkRequest.self, from: Data(example.utf8))
    try expectJSON(request, matches: example)
}

@Test func shareLinkIssueAndListJSONMatchDocumentedExamples() throws {
    let id = try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000002"))
    let expiresAt = Date(timeIntervalSince1970: 1_792_326_896)
    let shareLink = AdminShareLink(id: id, fileName: "report.pdf", expiresAt: expiresAt)
    let shareLinkExample = """
        {
          "id": "00000000-0000-4000-8000-000000000002",
          "fileName": "report.pdf",
          "expiresAt": "2026-10-18T12:34:56Z"
        }
        """
    try expectJSON(shareLink, matches: shareLinkExample)
    try expectJSON(
        AdminShareLinkIssueResponse(shareLink: shareLink, secret: "<secret>"),
        matches: """
            {"shareLink":\(shareLinkExample),"secret":"<secret>"}
            """)
    try expectJSON(
        AdminShareLinksResponse(shareLinks: [shareLink]),
        matches: """
            {"shareLinks":[\(shareLinkExample)]}
            """)
    let decoded = try AdminAPIJSON.makeDecoder().decode(AdminShareLink.self, from: Data(shareLinkExample.utf8))
    #expect(decoded == shareLink)
}
