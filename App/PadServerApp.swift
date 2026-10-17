import SwiftUI

@main
struct PadServerApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
                .task { await Composition.run() }
        }
    }
}
