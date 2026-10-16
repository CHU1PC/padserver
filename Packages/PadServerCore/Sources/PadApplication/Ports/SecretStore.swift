import PadDomain

public protocol SecretStore: Sendable {
    func secret(named name: String, for project: ProjectName) async throws -> String?
    func setSecret(_ value: String, named name: String, for project: ProjectName) async throws
    func secretNames(for project: ProjectName) async throws -> [String]
    func removeSecret(named name: String, for project: ProjectName) async throws
    func adminToken() async throws -> AdminToken?
    func setAdminToken(_ token: AdminToken) async throws
}
