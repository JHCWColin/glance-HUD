import SwiftUI

@main
struct HUDAppApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = BLEViewModel()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(viewModel)
        }
        .onChange(of: scenePhase) { newPhase in
            viewModel.handleScenePhase(newPhase)
        }
    }
}
