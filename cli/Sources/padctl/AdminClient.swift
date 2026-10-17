import Foundation
import PadApplication
import PadDomain
import PadInterface

enum AdminClientError: Error, CustomStringConvertible, Equatable {
    case notLoggedIn
    case connectionFailed
    case invalidResponse
    case server(status: Int, code: AdminErrorCode?, message: String?)

    var description: String {
        switch self {
        case .notLoggedIn:
            "You are not logged in. Run `padctl login <server URL>` first."

        case .connectionFailed:
            "Could not connect to the server. Check that the device is on the tailnet and the server is running."

        case .invalidResponse:
            "The server returned a response that padctl could not read."

        case .server(let status, let code, let message):
            Self.describeServerError(status: status, code: code, message: message)
        }
    }

    private static func describeServerError(status: Int, code: AdminErrorCode?, message: String?) -> String {
        switch code {
        case .unauthorized:
            "The token is missing or invalid. Run `padctl login <server URL>` again."

        case .forbidden:
            "The server refused this device. Connect from inside the tailnet."

        case .projectNotFound, .fileNotFound, .shareLinkNotFound:
            describeNotFound(code)

        case .deploymentIncomplete:
            "The deployment is incomplete: some blobs are missing or the project cannot take this action now."

        case .payloadTooLarge:
            "The upload is larger than the server accepts."

        case .invalidRequest:
            "The server rejected the request: \(message ?? "invalid request")"

        case .internalError:
            "The server failed to handle the request. Try again later."

        case nil:
            "The server returned HTTP \(status)."
        }
    }

    private static func describeNotFound(_ code: AdminErrorCode?) -> String {
        switch code {
        case .fileNotFound:
            "The file was not found on the server."

        case .shareLinkNotFound:
            "The share link was not found on the server."

        default:
            "The project was not found on the server."
        }
    }
}

struct AdminClient: Sendable {
    // 通常の要求が応答を待つ上限. 管理 API は tailnet 内の小さな JSON なので短くてよい.
    private static let requestTimeout: TimeInterval = 30
    // ログが流れない間も購読を保つため, streaming の待ちは1日まで許す.
    private static let streamTimeout: TimeInterval = 86_400

    private let serverURL: URL
    private let token: String
    private let session: URLSession

    init(configStore: any ConfigStore, tokenStore: any TokenStore, session: URLSession = .shared) throws {
        guard let config = try configStore.load(), let token = try tokenStore.load(), !token.isEmpty else {
            throw AdminClientError.notLoggedIn
        }
        serverURL = config.serverURL
        self.token = token
        self.session = session
    }

    func diffDeployment(
        project: ProjectName,
        request: AdminDeploymentRequest
    ) async throws -> AdminDeploymentDiffResponse {
        let urlRequest = try makeRequest(.post, ["projects", project.value, "deployments", "diff"], body: request)
        return try await send(urlRequest, expecting: [Status.success])
    }

    func uploadBlob(hash: BlobHash, file: URL) async throws {
        let request = makeRequest(.put, ["blobs", hash.value], contentType: "application/octet-stream")
        let (data, response) = try await perform { try await session.upload(for: request, fromFile: file) }
        try validate(response, data: data, expecting: [Status.created, Status.noContent])
    }

    func commitDeployment(
        project: ProjectName,
        request: AdminDeploymentRequest
    ) async throws -> AdminDeploymentResponse {
        let urlRequest = try makeRequest(.post, ["projects", project.value, "deployments"], body: request)
        return try await send(urlRequest, expecting: [Status.created])
    }

    func listProjects() async throws -> AdminProjectsResponse {
        try await send(makeRequest(.get, ["projects"]), expecting: [Status.success])
    }

    func startProject(_ project: ProjectName) async throws -> AdminProjectStatus {
        try await send(makeRequest(.post, ["projects", project.value, "start"]), expecting: [Status.success])
    }

    func stopProject(_ project: ProjectName) async throws -> AdminProjectStatus {
        try await send(makeRequest(.post, ["projects", project.value, "stop"]), expecting: [Status.success])
    }

    func uploadFile(name: String, from file: URL) async throws -> StoredFile {
        let request = makeRequest(.put, ["files", name], contentType: "application/octet-stream")
        let (data, response) = try await perform { try await session.upload(for: request, fromFile: file) }
        try validate(response, data: data, expecting: [Status.created])
        do {
            return try AdminAPIJSON.makeDecoder().decode(StoredFile.self, from: data)
        } catch {
            throw AdminClientError.invalidResponse
        }
    }

    func downloadFile(name: String, to destination: URL) async throws {
        let request = makeRequest(.get, ["files", name])
        let (temporary, response) = try await perform { try await session.download(for: request) }
        guard let http = response as? HTTPURLResponse else {
            throw AdminClientError.invalidResponse
        }
        guard http.statusCode == Status.success else {
            let body = try Data(contentsOf: temporary)
            try FileManager.default.removeItem(at: temporary)
            throw Self.makeServerError(status: http.statusCode, data: body)
        }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }

    func listFiles() async throws -> AdminFilesResponse {
        try await send(makeRequest(.get, ["files"]), expecting: [Status.success])
    }

    func deleteFile(name: String) async throws {
        let request = makeRequest(.delete, ["files", name])
        let (data, response) = try await perform { try await session.data(for: request) }
        try validate(response, data: data, expecting: [Status.noContent])
    }

    func issueShareLink(fileName: String, expiresAt: Date) async throws -> AdminShareLinkIssueResponse {
        let request = try makeRequest(
            .post, ["files", fileName, "share-links"], body: AdminShareLinkRequest(expiresAt: expiresAt))
        return try await send(request, expecting: [Status.created])
    }

    func listShareLinks() async throws -> AdminShareLinksResponse {
        try await send(makeRequest(.get, ["share-links"]), expecting: [Status.success])
    }

    func revokeShareLink(id: UUID) async throws {
        let request = makeRequest(.delete, ["share-links", id.uuidString])
        let (data, response) = try await perform { try await session.data(for: request) }
        try validate(response, data: data, expecting: [Status.noContent])
    }

    func streamLogs() async throws -> AsyncThrowingStream<LogEntry, any Error> {
        var request = makeRequest(.get, ["logs", "stream"])
        request.timeoutInterval = Self.streamTimeout
        let (bytes, response) = try await perform { try await session.bytes(for: request) }
        guard let http = response as? HTTPURLResponse else {
            throw AdminClientError.invalidResponse
        }
        guard http.statusCode == Status.success else {
            var data = Data()
            for try await byte in bytes {
                data.append(byte)
            }
            throw Self.makeServerError(status: http.statusCode, data: data)
        }
        return Self.makeLogStream(bytes)
    }

    private static func makeLogStream(_ bytes: URLSession.AsyncBytes) -> AsyncThrowingStream<LogEntry, any Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let decoder = AdminAPIJSON.makeDecoder()
                    for try await line in bytes.lines {
                        continuation.yield(try decoder.decode(LogEntry.self, from: Data(line.utf8)))
                    }
                    continuation.finish()
                } catch is DecodingError {
                    continuation.finish(throwing: AdminClientError.invalidResponse)
                } catch is CancellationError {
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: AdminClientError.connectionFailed)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func makeRequest(
        _ method: HTTPMethod,
        _ components: [String],
        contentType: String? = nil
    ) -> URLRequest {
        let url = (["v1"] + components).reduce(serverURL) { $0.appending(component: $1) }
        var request = URLRequest(url: url)
        request.httpMethod = method.rawValue
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }
        return request
    }

    private func makeRequest(
        _ method: HTTPMethod,
        _ components: [String],
        body: some Encodable
    ) throws -> URLRequest {
        var request = makeRequest(method, components, contentType: "application/json")
        request.httpBody = try AdminAPIJSON.makeEncoder().encode(body)
        return request
    }

    private func send<Response: Decodable>(
        _ request: URLRequest,
        expecting statuses: Set<Int>
    ) async throws -> Response {
        let (data, response) = try await perform { try await session.data(for: request) }
        try validate(response, data: data, expecting: statuses)
        do {
            return try AdminAPIJSON.makeDecoder().decode(Response.self, from: data)
        } catch {
            throw AdminClientError.invalidResponse
        }
    }

    private func perform<Output>(_ operation: () async throws -> Output) async throws -> Output {
        do {
            return try await operation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw AdminClientError.connectionFailed
        }
    }

    private func validate(_ response: URLResponse, data: Data, expecting statuses: Set<Int>) throws {
        guard let http = response as? HTTPURLResponse else {
            throw AdminClientError.invalidResponse
        }
        guard statuses.contains(http.statusCode) else {
            throw Self.makeServerError(status: http.statusCode, data: data)
        }
    }

    private static func makeServerError(status: Int, data: Data) -> AdminClientError {
        do {
            let body = try AdminAPIJSON.makeDecoder().decode(AdminErrorResponse.self, from: data)
            return .server(status: status, code: body.error.code, message: body.error.message)
        } catch {
            // 本文が管理 API の形でない応答 (proxy の 502 など) は status だけで伝える.
            return .server(status: status, code: nil, message: nil)
        }
    }
}

private enum HTTPMethod: String {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case delete = "DELETE"
}

private enum Status {
    static let success = 200
    static let created = 201
    static let noContent = 204
}
