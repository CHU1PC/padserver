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

public struct AdminFilesResponse: Codable, Hashable, Sendable {
    public let files: [StoredFile]

    public init(files: [StoredFile]) {
        self.files = files
    }
}

public struct AdminShareLinkRequest: Codable, Hashable, Sendable {
    public let expiresAt: Date

    public init(expiresAt: Date) {
        self.expiresAt = expiresAt
    }
}

public struct AdminShareLink: Codable, Hashable, Sendable {
    public let id: UUID
    public let fileName: String
    public let expiresAt: Date

    public init(id: UUID, fileName: String, expiresAt: Date) {
        self.id = id
        self.fileName = fileName
        self.expiresAt = expiresAt
    }
}

public struct AdminShareLinkIssueResponse: Codable, Hashable, Sendable {
    public let shareLink: AdminShareLink
    public let secret: String

    public init(shareLink: AdminShareLink, secret: String) {
        self.shareLink = shareLink
        self.secret = secret
    }
}

public struct AdminShareLinksResponse: Codable, Hashable, Sendable {
    public let shareLinks: [AdminShareLink]

    public init(shareLinks: [AdminShareLink]) {
        self.shareLinks = shareLinks
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
    case fileNotFound = "file_not_found"
    case shareLinkNotFound = "share_link_not_found"
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
