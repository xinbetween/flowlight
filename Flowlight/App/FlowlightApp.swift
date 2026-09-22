import SwiftUI

@main
struct FlowlightApp: App {
    @StateObject private var monitor = TrafficMonitor()
    @StateObject private var extensionManager = ExtensionManager()
    @StateObject private var nav = AppNavigation()

    var body: some Scene {
        WindowGroup("Flowlight", id: "main") {
            ContentView()
                .environmentObject(monitor)
                .environmentObject(extensionManager)
                .environmentObject(nav)
                .frame(minWidth: 1000, minHeight: 660)
                .task {
                    monitor.start()
                    extensionManager.refresh()
                }
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(before: .sidebar) {
                ForEach(SidebarItem.allCases) { item in
                    Button(item.title) { nav.selection = item }.keyboardShortcut(item.shortcut, modifiers: .command)
                }
                Divider()
            }
        }

        Window("Name Your Traffic", id: "capture-onboarding") {
            CaptureOnboardingView()
                .environmentObject(monitor)
                .onAppear { monitor.markCaptureOnboardingShown() }
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(monitor)
                .environmentObject(nav)
        } label: {
            MenuBarLabel().environmentObject(monitor)
        }

        Settings {
            SettingsView().environmentObject(monitor)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @AppStorage(AnomalySettings.Keys.menuBarRates) private var showRates = true

    var body: some View {
        if showRates {
            Text("↓\(ByteFormat.compact(monitor.currentIn)) ↑\(ByteFormat.compact(monitor.currentOut))")
                .monospacedDigit()
        } else {
            Image(systemName: monitor.unacknowledgedAlerts > 0 ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.up.arrow.down.circle")
        }
    }
}
