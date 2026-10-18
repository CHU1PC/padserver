import PadApplication
import PadDomain
import PadInterface
import SwiftUI

struct ProjectList: View {
    let logBus: any LogBus
    let load: @Sendable () async throws -> [ListProjects.Status]
    let loadUsage: @Sendable (String) async throws -> ProjectUsage?

    @State private var rows: [ProjectListRow] = []
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if rows.isEmpty {
                Text("No projects")
                    .foregroundStyle(.secondary)
            }
            ForEach(rows) { row in
                NavigationLink(value: row.name) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(row.name).font(.headline)
                            Text(row.kind).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text(row.isRunning ? "Running" : "Stopped")
                                .foregroundStyle(row.isRunning ? .green : .secondary)
                            Text(row.activeRelease.map { "Release \($0)" } ?? "No release")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationDestination(for: String.self) { name in
            ProjectDetail(name: name, logBus: logBus, loadUsage: { try await loadUsage(name) })
        }
        .navigationTitle("Projects")
        .task { await reload() }
        .refreshable { await reload() }
    }

    private func reload() async {
        do {
            rows = ProjectListPresenter.rows(from: try await load())
            errorMessage = nil
        } catch {
            errorMessage = "Failed to load projects"
        }
    }
}
