import PadApplication
import PadDomain

public struct ProjectListRow: Hashable, Sendable, Identifiable {
    public let name: String
    public let kind: String
    public let isRunning: Bool
    public let activeRelease: String?

    public var id: String { name }

    public init(name: String, kind: String, isRunning: Bool, activeRelease: String?) {
        self.name = name
        self.kind = kind
        self.isRunning = isRunning
        self.activeRelease = activeRelease
    }
}

public enum ProjectListPresenter {
    // release の ID は UUID の先頭8文字で見分けられる.
    private static let releaseLabelLength = 8

    /// use case の結果を、画面に出す行へ変換します。順序は保ちます。
    public static func rows(from statuses: [ListProjects.Status]) -> [ProjectListRow] {
        statuses.map { status in
            ProjectListRow(
                name: status.project.name.value,
                kind: kindLabel(status.project.kind),
                isRunning: status.running,
                activeRelease: status.activeRelease.map {
                    String($0.id.value.uuidString.lowercased().prefix(releaseLabelLength))
                })
        }
    }

    private static func kindLabel(_ kind: ProjectKind) -> String {
        switch kind {
        case .staticSite: "Static site"
        case .compose: "Compose"
        }
    }
}
