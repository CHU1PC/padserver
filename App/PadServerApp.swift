import PadApplication
import PadInfrastructure
import SwiftUI

@main
struct PadServerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    private let logBus: any LogBus
    @State private var lifecycle: Lifecycle

    init() {
        let logBus = InMemoryLogBus()
        self.logBus = logBus
        _lifecycle = State(initialValue: Lifecycle(logBus: logBus))
    }

    var body: some Scene {
        WindowGroup {
            RootView(logBus: logBus)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    switch phase {
                    case .active:
                        lifecycle.becomeActive()

                    case .background:
                        lifecycle.enterBackground()

                    case .inactive:
                        break

                    @unknown default:
                        break
                    }
                }
        }
    }
}
