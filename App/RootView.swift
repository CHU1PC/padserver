import PadInfrastructure
import SwiftUI

struct RootView: View {
    private let adminEndpoint = Composition.tailnetAddress().map { "http://\($0):\(Composition.adminPort)" }

    var body: some View {
        TabView {
            SetupScreen(secretStore: KeychainSecretStore(), adminEndpoint: adminEndpoint)
                .tabItem { Label("Setup", systemImage: "key") }
            NavigationStack {
                ProjectList(load: { try await Composition.listProjects() })
            }
            .tabItem { Label("Projects", systemImage: "square.stack") }
        }
    }
}
