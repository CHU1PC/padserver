import Foundation
import PadApplication
import PadDomain

public struct AdminDeploymentFile: Codable, Hashable, Sendable {
    public let path: String
    public let hash: BlobHash

    public init(path: String, hash: BlobHash) {
        self.path = path
        self.hash = hash
    }
}

public struct AdminDeploymentRequest: Codable, Hashable, Sendable {
    public let manifest: ProjectManifest
    public let files: [AdminDeploymentFile]

    public init(manifest: ProjectManifest, files: [AdminDeploymentFile]) {
        self.manifest = manifest
        self.files = files
    }
}

public struct AdminDeploymentDiffResponse: Codable, Hashable, Sendable {
    public let missingBlobs: [AdminDeploymentFile]

    public init(missingBlobs: [AdminDeploymentFile]) {
        self.missingBlobs = missingBlobs
    }
}

public struct AdminDeploymentResponse: Codable, Hashable, Sendable {
    public let project: Project
    public let release: Release

    public init(project: Project, release: Release) {
        self.project = project
        self.release = release
    }
}

public struct AdminProjectStatus: Codable, Hashable, Sendable {
    public let project: Project
    public let activeRelease: Release?
    public let running: Bool

    public init(project: Project, activeRelease: Release?, running: Bool) {
        self.project = project
        self.activeRelease = activeRelease
        self.running = running
    }

    private enum CodingKeys: String, CodingKey {
        case project
        case activeRelease
        case running
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(project, forKey: .project)
        try container.encode(activeRelease, forKey: .activeRelease)
        try container.encode(running, forKey: .running)
    }
}

public struct AdminProjectsResponse: Codable, Hashable, Sendable {
    public let projects: [AdminProjectStatus]

    public init(projects: [AdminProjectStatus]) {
        self.projects = projects
    }
}

public enum AdminErrorCode: String, Codable, Hashable, Sendable {
    case invalidRequest = "invalid_request"
    case unauthorized
    case forbidden
    case projectNotFound = "project_not_found"
    case deploymentIncomplete = "deployment_incomplete"
    case payloadTooLarge = "payload_too_large"
    case internalError = "internal_error"
}

public struct AdminError: Codable, Hashable, Sendable {
    public let code: AdminErrorCode
    public let message: String

    public init(code: AdminErrorCode, message: String) {
        self.code = code
        self.message = message
    }
}

public struct AdminErrorResponse: Codable, Hashable, Sendable {
    public let error: AdminError

    public init(error: AdminError) {
        self.error = error
    }
}

public enum AdminAPIJSON {
    public static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
