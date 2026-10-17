import ArgumentParser
import PadDomain

struct ProjectLifecycleService {
    private let client: AdminClient

    init(client: AdminClient) {
        self.client = client
    }

    func start(projectName: String) async throws -> String {
        let status = try await client.startProject(Self.makeProjectName(projectName))
        return Self.describe(status.project.name, running: status.running)
    }

    func stop(projectName: String) async throws -> String {
        let status = try await client.stopProject(Self.makeProjectName(projectName))
        return Self.describe(status.project.name, running: status.running)
    }

    private static func makeProjectName(_ value: String) throws -> ProjectName {
        do {
            return try ProjectName(value)
        } catch {
            throw ValidationError("The project name must use letters, digits and hyphens, up to 63 characters.")
        }
    }

    private static func describe(_ name: ProjectName, running: Bool) -> String {
        "Project \(name.value) is \(running ? "running" : "stopped")."
    }
}

private func makeLifecycleService() throws -> ProjectLifecycleService {
    ProjectLifecycleService(
        client: try AdminClient(
            configStore: ConfigFileStore(fileURL: ConfigFileStore.defaultFileURL()),
            tokenStore: KeychainTokenStore()
        )
    )
}

struct Start: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Start a project on the server."
    )

    @Argument(help: "Name of the project to start.")
    var project: String

    mutating func run() async throws {
        print(try await makeLifecycleService().start(projectName: project))
    }
}

struct Stop: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Stop a project on the server."
    )

    @Argument(help: "Name of the project to stop.")
    var project: String

    mutating func run() async throws {
        print(try await makeLifecycleService().stop(projectName: project))
    }
}
