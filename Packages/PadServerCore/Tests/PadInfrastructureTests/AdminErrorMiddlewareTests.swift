import Foundation
import Hummingbird
import HummingbirdTesting
import PadApplication
import PadDomain
import PadInfrastructure
import PadInterface
import Testing

private struct UnexpectedFailure: Error, CustomStringConvertible {
    let description = "/Users/example/secret/path stack: frame#0"
}

private func makeApplication(
    routes: @escaping @Sendable (Router<AdminRequestContext>) -> Void
) -> some ApplicationProtocol {
    let router = Router(context: AdminRequestContext.self)
    router.add(middleware: AdminErrorMiddleware())
    routes(router)
    return Application(responder: router.buildResponder())
}

private struct ErrorCase {
    let error: Error
    let status: HTTPResponse.Status
    let code: AdminErrorCode
}

private func expectError(
    _ response: TestResponse, status: HTTPResponse.Status, code: AdminErrorCode
) throws {
    #expect(response.status == status)
    #expect(response.headers[.contentType] == "application/json")
    let decoded = try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: response.body)
    #expect(decoded.error.code == code)
    #expect(!decoded.error.message.isEmpty)
}

@Test func adminErrorMiddlewareMapsFailuresToSpecifiedErrors() async throws {
    let blob = BlobHash(String(repeating: "a", count: 64))
    let cases = [
        ErrorCase(error: CommitDeployment.Failure.blobNotFound(blob), status: .conflict, code: .deploymentIncomplete),
        ErrorCase(
            error: FileProjectStorage.Failure.operationInProgress, status: .conflict, code: .deploymentIncomplete),
        ErrorCase(error: FileProjectStorage.Failure.projectNotFound, status: .notFound, code: .projectNotFound),
        ErrorCase(error: ProjectName.ValidationError.invalidName, status: .badRequest, code: .invalidRequest),
        ErrorCase(error: ProjectManifest.ValidationError.noRoutes, status: .badRequest, code: .invalidRequest),
        ErrorCase(
            error: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")), status: .badRequest,
            code: .invalidRequest),
        ErrorCase(error: HTTPError(.contentTooLarge), status: .contentTooLarge, code: .payloadTooLarge),
        ErrorCase(error: HTTPError(.notFound), status: .notFound, code: .projectNotFound),
        ErrorCase(error: HTTPError(.badRequest), status: .badRequest, code: .invalidRequest),
        ErrorCase(error: HTTPError(.forbidden), status: .internalServerError, code: .internalError),
    ]

    for testCase in cases {
        let application = makeApplication { router in
            router.get("/probe") { _, _ -> Response in throw testCase.error }
        }
        try await application.test(.router) { client in
            let response = try await client.execute(uri: "/probe", method: .get)
            try expectError(response, status: testCase.status, code: testCase.code)
        }
    }
}

@Test func adminErrorMiddlewareHidesInternalDetails() async throws {
    let application = makeApplication { router in
        router.get("/probe") { _, _ -> Response in throw UnexpectedFailure() }
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/probe", method: .get)
        try expectError(response, status: .internalServerError, code: .internalError)
        let body = String(buffer: response.body)
        #expect(!body.contains("/Users"))
        #expect(!body.contains("stack"))
    }
}

@Test func adminErrorMiddlewareReturnsUnknownEndpointAsNotFoundJSON() async throws {
    let application = makeApplication { _ in
        // 経路を登録しない。
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/missing", method: .get)
        try expectError(response, status: .notFound, code: .projectNotFound)
    }
}

@Test func adminErrorMiddlewarePassesSuccessfulResponses() async throws {
    let application = makeApplication { router in
        router.get("/probe") { _, _ in Response(status: .noContent) }
    }
    try await application.test(.router) { client in
        let response = try await client.execute(uri: "/probe", method: .get)
        #expect(response.status == .noContent)
    }
}
