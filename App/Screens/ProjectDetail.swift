import PadApplication
import PadDomain
import PadInterface
import SwiftUI

struct ProjectDetail: View {
    private static let refreshSeconds = 5

    let name: String
    let logBus: any LogBus
    let loadUsage: @Sendable () async throws -> ProjectUsage?

    @State private var display: ProjectUsageDisplay?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            usageSection
            Divider()
            LogFeed(logBus: logBus, project: name)
        }
        .navigationTitle(name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await pollUsage() }
    }

    private var usageSection: some View {
        VStack(alignment: .leading) {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let display {
                Text("CPU: \(display.cpu)")
                Text("Memory: \(display.memory)")
            } else {
                Text("Loading usage").foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
    }

    private func pollUsage() async {
        while !Task.isCancelled {
            do {
                display = ProjectUsagePresenter.display(for: try await loadUsage())
                errorMessage = nil
            } catch {
                errorMessage = "Failed to load usage"
            }
            do {
                try await Task.sleep(for: .seconds(Self.refreshSeconds))
            } catch {
                return
            }
        }
    }
}
