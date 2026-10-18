import PadInterface
import SwiftUI

struct GuestStatus: View {
    private static let refreshSeconds = 5

    let load: @Sendable () async throws -> GuestStatusReading?

    @State private var display: GuestStatusDisplay?
    @State private var errorMessage: String?

    var body: some View {
        List {
            if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let display {
                LabeledContent("State", value: display.state)
                LabeledContent("Memory", value: display.memory)
                LabeledContent("Disk", value: display.disk)
            } else {
                Text("Loading guest status").foregroundStyle(.secondary)
            }
        }
        .task { await poll() }
    }

    private func poll() async {
        while !Task.isCancelled {
            do {
                display = GuestStatusPresenter.display(for: try await load())
                errorMessage = nil
            } catch {
                errorMessage = "Failed to load guest status"
            }
            do {
                try await Task.sleep(for: .seconds(Self.refreshSeconds))
            } catch {
                return
            }
        }
    }
}
