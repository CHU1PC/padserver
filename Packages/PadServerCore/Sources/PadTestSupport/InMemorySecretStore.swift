import PadApplication
import PadDomain

public actor InMemorySecretStore: SecretStore {
    private struct SecretKey: Hashable {
        let project: ProjectName
        let name: String
    }

    private var secrets: [SecretKey: String] = [:]
    private var currentAdminToken: AdminToken?

    public init() {
        // 明示した初期化子で公開 API を安定させます。
    }

    public func secret(named name: String, for project: ProjectName) throws -> String? {
        secrets[SecretKey(project: project, name: name)]
    }

    public func setSecret(_ value: String, named name: String, for project: ProjectName) throws {
        secrets[SecretKey(project: project, name: name)] = value
    }

    public func secretNames(for project: ProjectName) throws -> [String] {
        secrets.keys.filter { $0.project == project }.map(\.name).sorted()
    }

    public func removeSecret(named name: String, for project: ProjectName) throws {
        secrets[SecretKey(project: project, name: name)] = nil
    }

    public func adminToken() throws -> AdminToken? {
        currentAdminToken
    }

    public func setAdminToken(_ token: AdminToken) throws {
        currentAdminToken = token
    }
}
