import SwiftUI

struct MainShellView: View {
    @EnvironmentObject private var app: AppModel

    var body: some View {
        TabView {
            NavigationStack {
                LiveCrisisMapScreen()
            }
            .tabItem {
                Label("Map", systemImage: "map.fill")
            }

            NavigationStack {
                ReportCrisisScreen()
            }
            .tabItem {
                Label("Report", systemImage: "plus.message.fill")
            }

            NavigationStack {
                SignalInboxScreen()
            }
            .tabItem {
                Label("Inbox", systemImage: "tray.full.fill")
            }

            NavigationStack {
                SettingsScreen()
            }
            .tabItem {
                Label("Settings", systemImage: "gearshape.fill")
            }
        }
        .tint(AppTheme.blue)
    }
}
