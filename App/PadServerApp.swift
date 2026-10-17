import PadInfrastructure
import SwiftUI

@main
struct PadServerApp: App {
    private let logBus = InMemoryLogBus()

    var body: some Scene {
        WindowGroup {
            RootView(logBus: logBus)
                .task { await Composition.run(logBus: logBus) }
        }
    }
}
