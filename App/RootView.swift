import PadApplication
import PadInfrastructure
import SwiftUI

struct RootView: View {
    let logBus: any LogBus
    private let adminEndpoint = Composition.tailnetAddress().map { "http://\($0):\(Composition.adminPort)" }

    var body: some View {
        TabView {
            SetupScreen(secretStore: KeychainSecretStore(), adminEndpoint: adminEndpoint)
                .tabItem { Label("Setup", systemImage: "key") }
            NavigationStack {
                ProjectList(
                    logBus: logBus,
                    load: { try await Composition.listProjects() },
                    loadUsage: { try await Composition.projectUsage(of: $0) })
            }
            .tabItem { Label("Projects", systemImage: "square.stack") }
            NavigationStack {
                GuestStatus(load: { await Composition.guestStatus() })
                    .navigationTitle("Guest")
            }
            .tabItem { Label("Guest", systemImage: "desktopcomputer") }
            RequestFeed(logBus: logBus)
                .tabItem { Label("Requests", systemImage: "arrow.left.arrow.right") }
            LogFeed(logBus: logBus)
                .tabItem { Label("Logs", systemImage: "text.alignleft") }
        }
    }
}
