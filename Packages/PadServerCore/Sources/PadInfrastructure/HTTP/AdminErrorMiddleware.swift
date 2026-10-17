import Foundation
import Hummingbird
import NIOCore
import PadApplication
import PadDomain
import PadInterface

public struct AdminErrorMiddleware: RouterMiddleware {
    public init() {
        // 保持する状態は無い。
    }

    public func handle(
        _ request: Request, context: AdminRequestContext,
        next: (Request, AdminRequestContext) async throws -> Response
    ) async throws -> Response {
        do {
            return try await next(request, context)
        } catch {
            // 想定外の失敗も含めて、全て仕様のエラーの形に変える。
            return try Self.response(for: error)
        }
    }

    private struct Mapping {
        let status: HTTPResponse.Status
        let code: AdminErrorCode
        let message: String
    }

    private static func response(for error: Error) throws -> Response {
        let mapping = Self.classify(error)
        let body = AdminErrorResponse(error: AdminError(code: mapping.code, message: mapping.message))
        let data = try AdminAPIJSON.makeEncoder().encode(body)
        return Response(
            status: mapping.status,
            headers: [.contentType: "application/json"],
            body: .init(byteBuffer: ByteBuffer(data: data))
        )
    }

    private static func classify(_ error: Error) -> Mapping {
        switch error {
        case CommitDeployment.Failure.blobNotFound, FileProjectStorage.Failure.operationInProgress:
            return Mapping(
                status: .conflict, code: .deploymentIncomplete,
                message: "Deployment cannot be completed in the current state.")

        case FileProjectStorage.Failure.projectNotFound:
            return notFound

        case let httpError as HTTPError:
            return classify(httpError)

        case is DecodingError, is ProjectName.ValidationError, is ProjectManifest.ValidationError,
            is RouteHost.ValidationError, is RoutePathPrefix.ValidationError,
            is ContainerRouteTarget.ValidationError:
            return badRequest

        default:
            return internalError
        }
    }

    private static func classify(_ error: HTTPError) -> Mapping {
        switch error.status {
        case .notFound:
            return notFound

        case .contentTooLarge:
            return Mapping(status: .contentTooLarge, code: .payloadTooLarge, message: "Request body is too large.")

        case .badRequest:
            return badRequest

        default:
            return internalError
        }
    }

    private static let notFound = Mapping(status: .notFound, code: .projectNotFound, message: "Project was not found.")
    private static let badRequest = Mapping(status: .badRequest, code: .invalidRequest, message: "Request is invalid.")
    private static let internalError = Mapping(
        status: .internalServerError, code: .internalError, message: "Internal server error.")
}
