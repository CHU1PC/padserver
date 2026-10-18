import Foundation

public struct ContainerSummary: Decodable, Equatable, Sendable {
    public let id: String
    public let names: [String]
    public let image: String
    public let state: String
    public let status: String
    public let labels: [String: String]

    public init(
        id: String, names: [String], image: String, state: String, status: String, labels: [String: String] = [:]
    ) {
        self.id = id
        self.names = names
        self.image = image
        self.state = state
        self.status = status
        self.labels = labels
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        names = try container.decode([String].self, forKey: .names)
        image = try container.decode(String.self, forKey: .image)
        state = try container.decode(String.self, forKey: .state)
        status = try container.decode(String.self, forKey: .status)
        labels = try container.decodeIfPresent([String: String].self, forKey: .labels) ?? [:]
    }

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
        case names = "Names"
        case image = "Image"
        case state = "State"
        case status = "Status"
        case labels = "Labels"
    }
}

public struct ContainerPortBinding: Encodable, Equatable, Sendable {
    public let hostIP: String?
    public let hostPort: String

    public init(hostIP: String? = nil, hostPort: String) {
        self.hostIP = hostIP
        self.hostPort = hostPort
    }

    private enum CodingKeys: String, CodingKey {
        case hostIP = "HostIp"
        case hostPort = "HostPort"
    }
}

public struct ContainerHostConfig: Encodable, Equatable, Sendable {
    public let portBindings: [String: [ContainerPortBinding]]

    public init(portBindings: [String: [ContainerPortBinding]]) {
        self.portBindings = portBindings
    }

    private enum CodingKeys: String, CodingKey {
        case portBindings = "PortBindings"
    }
}

public struct CreateContainerRequest: Encodable, Equatable, Sendable {
    private struct EmptyObject: Encodable {}

    public let image: String
    public let cmd: [String]?
    public let env: [String]?
    /// "80/tcp" の形の port の一覧.
    public let exposedPorts: [String]?
    public let hostConfig: ContainerHostConfig?

    public init(
        image: String, cmd: [String]? = nil, env: [String]? = nil, exposedPorts: [String]? = nil,
        hostConfig: ContainerHostConfig? = nil
    ) {
        self.image = image
        self.cmd = cmd
        self.env = env
        self.exposedPorts = exposedPorts
        self.hostConfig = hostConfig
    }

    private enum CodingKeys: String, CodingKey {
        case image = "Image"
        case cmd = "Cmd"
        case env = "Env"
        case exposedPorts = "ExposedPorts"
        case hostConfig = "HostConfig"
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(image, forKey: .image)
        try container.encodeIfPresent(cmd, forKey: .cmd)
        try container.encodeIfPresent(env, forKey: .env)
        try container.encodeIfPresent(
            exposedPorts.map { Dictionary(uniqueKeysWithValues: $0.map { ($0, EmptyObject()) }) },
            forKey: .exposedPorts)
        try container.encodeIfPresent(hostConfig, forKey: .hostConfig)
    }
}

private struct CreatedContainer: Decodable {
    let id: String

    private enum CodingKeys: String, CodingKey {
        case id = "Id"
    }
}

private struct WaitResult: Decodable {
    let statusCode: Int

    private enum CodingKeys: String, CodingKey {
        case statusCode = "StatusCode"
    }
}

@available(macOS 13, iOS 16, *)
extension DockerClient {
    public enum ContainerError: Error, Equatable, Sendable {
        case notFound
        case conflict
    }

    private enum ContainerConstants {
        static let okStatus = 200
        static let createdStatus = 201
        static let noContentStatus = 204
        static let notModifiedStatus = 304
        static let noContentOrNotModified = [noContentStatus, notModifiedStatus]
        static let notFoundStatus = 404
        static let conflictStatus = 409
        // 終了待ちは container が終わるまで応答が無いので, 既定の 60 秒より長く待つ (1 日)
        static let waitTimeoutSeconds: TimeInterval = 86_400
    }

    public func listContainers(all: Bool = false) async throws -> [ContainerSummary] {
        let query = all ? [URLQueryItem(name: "all", value: "true")] : []
        let response = try await send(method: "GET", path: "/containers/json", query: query)
        try Self.expect(response.status, in: [ContainerConstants.okStatus])
        return try Self.decode([ContainerSummary].self, from: response.body)
    }

    /// 作った container の ID を返す.
    public func createContainer(_ request: CreateContainerRequest, name: String? = nil) async throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let query = name.map { [URLQueryItem(name: "name", value: $0)] } ?? []
        let response = try await send(
            method: "POST", path: "/containers/create", query: query, body: try encoder.encode(request))
        try Self.expect(response.status, in: [ContainerConstants.createdStatus])
        return try Self.decode(CreatedContainer.self, from: response.body).id
    }

    /// 既に開始済み (304) でも成功にする.
    public func startContainer(id: String) async throws {
        let response = try await send(method: "POST", path: "/containers/\(id)/start")
        try Self.expect(response.status, in: ContainerConstants.noContentOrNotModified)
    }

    /// 既に停止済み (304) でも成功にする.
    public func stopContainer(id: String) async throws {
        let response = try await send(method: "POST", path: "/containers/\(id)/stop")
        try Self.expect(response.status, in: ContainerConstants.noContentOrNotModified)
    }

    public func removeContainer(id: String) async throws {
        let response = try await send(method: "DELETE", path: "/containers/\(id)")
        try Self.expect(response.status, in: [ContainerConstants.noContentStatus])
    }

    /// container が終わるまで待って, 終了コードを返す.
    public func waitContainer(id: String) async throws -> Int {
        let response = try await send(
            method: "POST", path: "/containers/\(id)/wait", timeout: ContainerConstants.waitTimeoutSeconds)
        try Self.expect(response.status, in: [ContainerConstants.okStatus])
        return try Self.decode(WaitResult.self, from: response.body).statusCode
    }

    private static func expect(_ status: Int, in accepted: [Int]) throws {
        if accepted.contains(status) { return }
        switch status {
        case ContainerConstants.notFoundStatus: throw ContainerError.notFound
        case ContainerConstants.conflictStatus: throw ContainerError.conflict
        default: throw ClientError.unexpectedStatus(status)
        }
    }

    private static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw ClientError.invalidResponse
        }
    }
}
