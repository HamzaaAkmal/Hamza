import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var app: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var bootstrapped = false

    var body: some View {
        Group {
            if app.session == nil {
                AuthView()
            } else {
                MainShellView()
            }
        }
        .task {
            guard !bootstrapped else { return }
            bootstrapped = true
            app.bootstrap()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, app.session != nil else { return }
            Task { await app.repository.loadAll() }
        }
    }
}

#Preview {
    ContentView()
        .environmentObject(AppModel())
}
