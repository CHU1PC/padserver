import SwiftUI

struct RootView: View {
    var body: some View {
        NavigationStack {
            ProjectList(load: { try await Composition.listProjects() })
        }
    }
}
