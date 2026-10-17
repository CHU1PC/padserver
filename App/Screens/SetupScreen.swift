import PadApplication
import PadDomain
import SwiftUI

struct SetupScreen: View {
    let secretStore: any SecretStore
    let adminEndpoint: String?

    @State private var token: AdminToken?
    @State private var errorMessage: String?

    var body: some View {
        Form {
            Section("Admin endpoint") {
                Text(adminEndpoint ?? "Tailnet address not found")
                    .textSelection(.enabled)
            }
            Section("Admin token") {
                Text(token?.value ?? "-")
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                Button("Regenerate token") {
                    Task { await regenerate() }
                }
            }
            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
        }
        .task { await load() }
    }

    // 初回は token が無いので、その場で発行します。
    private func load() async {
        do {
            if let stored = try await secretStore.adminToken() {
                token = stored
            } else {
                token = try await IssueToken(secretStore: secretStore)()
            }
        } catch {
            errorMessage = "Failed to load the token: \(error)"
        }
    }

    private func regenerate() async {
        do {
            token = try await IssueToken(secretStore: secretStore)()
            errorMessage = nil
        } catch {
            errorMessage = "Failed to regenerate the token: \(error)"
        }
    }
}
