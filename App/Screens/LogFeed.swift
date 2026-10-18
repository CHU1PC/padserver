import PadApplication
import PadDomain
import PadInterface
import SwiftUI

struct LogFeed: View {
    let logBus: any LogBus

    @State private var presenter: LogFeedPresenter

    init(logBus: any LogBus, project: String? = nil) {
        self.logBus = logBus
        _presenter = State(initialValue: LogFeedPresenter(project: project))
    }

    var body: some View {
        ScrollViewReader { proxy in
            List(presenter.rows) { row in
                LogRowView(row: row)
            }
            .listStyle(.plain)
            .onChange(of: presenter.rows.last?.id) { _, lastID in
                guard let lastID else { return }
                proxy.scrollTo(lastID, anchor: .bottom)
            }
        }
        .overlay {
            if presenter.rows.isEmpty {
                ContentUnavailableView("No logs yet", systemImage: "text.alignleft")
            }
        }
        .task {
            for await entry in await logBus.subscribe() {
                presenter.append(entry)
            }
        }
    }
}

private struct LogRowView: View {
    let row: LogRow

    private let rowSpacing: CGFloat = 2

    var body: some View {
        VStack(alignment: .leading, spacing: rowSpacing) {
            HStack {
                Text(row.timestamp, format: .dateTime.hour().minute().second())
                Text(row.source)
                if let project = row.project {
                    Text(project)
                }
                Text(row.level.rawValue.uppercased()).foregroundStyle(color)
            }
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            Text(row.message)
        }
    }

    private var color: Color {
        switch row.level {
        case .debug: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}
