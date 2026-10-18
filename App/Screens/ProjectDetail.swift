import PadApplication
import SwiftUI

struct ProjectDetail: View {
    let name: String
    let logBus: any LogBus

    var body: some View {
        LogFeed(logBus: logBus, project: name)
            .navigationTitle(name)
            .navigationBarTitleDisplayMode(.inline)
    }
}
