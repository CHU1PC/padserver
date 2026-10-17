import PadApplication
import SwiftUI

struct RootView: View {
    let logBus: any LogBus

    var body: some View {
        LogFeed(logBus: logBus)
    }
}
