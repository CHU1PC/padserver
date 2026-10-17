import PadInfrastructure
import SwiftUI

struct RootView: View {
    private let adminEndpoint = Composition.tailnetAddress().map { "http://\($0):\(Composition.adminPort)" }

    var body: some View {
        SetupScreen(secretStore: KeychainSecretStore(), adminEndpoint: adminEndpoint)
    }
}
