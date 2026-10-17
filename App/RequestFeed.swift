import PadApplication
import PadInterface
import SwiftUI

struct RequestFeed: View {
    let logBus: any LogBus
    @State private var presenter = RequestFeedPresenter()

    var body: some View {
        List(presenter.rows) { row in
            HStack {
                Text("\(row.status)")
                    .monospacedDigit()
                    .foregroundStyle(row.isFailure ? .red : .green)
                VStack(alignment: .leading) {
                    Text(row.path)
                    Text(row.host).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(row.timestamp, format: .dateTime.hour().minute().second())
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .task {
            for await entry in await logBus.subscribe() {
                presenter.receive(entry)
            }
        }
    }
}
