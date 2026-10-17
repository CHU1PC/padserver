import SwiftUI

@main
struct PadServerApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var lifecycle = Lifecycle()

    var body: some Scene {
        WindowGroup {
            RootView()
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
