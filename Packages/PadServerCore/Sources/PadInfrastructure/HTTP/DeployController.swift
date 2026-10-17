import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct DeployController: Sendable {
    // 配備の JSON は manifest とファイル一覧だけなので、1 MiB あれば数千ファイルを収められる。
    private static let maximumRequestBytes = 1 << 20

    private let planDeployment: PlanDeployment
    private let commitDeployment: CommitDeployment

    public init(planDeployment: PlanDeployment, commitDeployment: CommitDeployment) {
        self.planDeployment = planDeployment
        self.commitDeployment = commitDeployment
    }

    public func addRoutes(to router: Router<AdminRequestContext>) {
        router.post("/v1/projects/{name}/deployments/diff", use: diff)
        router.post("/v1/projects/{name}/deployments", use: commit)
    }

    private func diff(_ request: Request, context: AdminRequestContext) async throws -> Response {
        do {
            let deployment = try await validatedDeployment(request, context: context)
            let missing = try await planDeployment.missingBlobs(from: deployment.manifest.files)
            let body = AdminDeploymentDiffResponse(
                missingBlobs: missing.map { AdminDeploymentFile(path: $0.path, hash: $0.blob) })
            return try jsonResponse(body, status: .ok)
        } catch let rejection as InvalidDeploymentRequest {
            return try errorResponse(.invalidRequest, message: rejection.message, status: .badRequest)
        }
    }

    private func commit(_ request: Request, context: AdminRequestContext) async throws -> Response {
        do {
            let deployment = try await validatedDeployment(request, context: context)
            let release = try await commitDeployment(project: deployment.project.name, manifest: deployment.manifest)
            return try jsonResponse(
                AdminDeploymentResponse(project: deployment.project, release: release), status: .created)
        } catch let rejection as InvalidDeploymentRequest {
            return try errorResponse(.invalidRequest, message: rejection.message, status: .badRequest)
        } catch CommitDeployment.Failure.blobNotFound {
            return try errorResponse(
                .deploymentIncomplete, message: "Required blobs are missing.", status: .conflict)
        }
    }

    private func validatedDeployment(
        _ request: Request, context: AdminRequestContext
    ) async throws -> ValidatedDeployment {
        let name: ProjectName
        do {
            name = try ProjectName(context.parameters.get("name") ?? "")
        } catch {
            throw InvalidDeploymentRequest(message: "Project name is invalid.")
        }

        let buffer = try await request.body.collect(upTo: Self.maximumRequestBytes)
        let decoded: AdminDeploymentRequest
        do {
            decoded = try AdminAPIJSON.makeDecoder().decode(
                AdminDeploymentRequest.self, from: Data(buffer.readableBytesView))
        } catch {
            throw InvalidDeploymentRequest(message: "Request body is invalid.")
        }
        guard decoded.manifest.name == name else {
            throw InvalidDeploymentRequest(message: "Manifest name does not match the project.")
        }

        let files = decoded.files.map { ReleaseManifestFile(path: $0.path, blob: $0.hash) }
        return ValidatedDeployment(
            project: Project(name: name, kind: .staticSite), manifest: ReleaseManifest(files: files))
    }

    private func jsonResponse<Body: Encodable>(_ body: Body, status: HTTPResponse.Status) throws -> Response {
        let data = try AdminAPIJSON.makeEncoder().encode(body)
        var headers = HTTPFields()
        headers[.contentType] = "application/json"
        return Response(status: status, headers: headers, body: .init(byteBuffer: ByteBuffer(bytes: data)))
    }

    private func errorResponse(
        _ code: AdminErrorCode, message: String, status: HTTPResponse.Status
    ) throws -> Response {
        try jsonResponse(AdminErrorResponse(error: AdminError(code: code, message: message)), status: status)
    }
}

private struct ValidatedDeployment {
    let project: Project
    let manifest: ReleaseManifest
}

private struct InvalidDeploymentRequest: Error {
    let message: String
}
