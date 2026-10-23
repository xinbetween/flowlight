import SwiftUI

/// Handles the one thing SwiftUI's scene lifecycle doesn't give cleanly: a hook that runs as the app quits, used to
/// strip the proxy routing Flowlight persisted into agents' settings files so a clean quit never leaves one pointing
/// at a proxy that is about to stop. A crash skips this; `ProxyJanitor` covers that.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static var didFinishLaunching = false
    private static var didStart = false
    private static var startup: (() -> Void)?

    static func installStartup(_ action: @escaping () -> Void) {
        guard !didStart else { return }
        startup = action
        runStartupIfReady()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.didFinishLaunching = true
        Self.runStartupIfReady()
    }

    private static func runStartupIfReady() {
        guard didFinishLaunching, !didStart, let startup else { return }
        didStart = true
        self.startup = nil
        startup()
    }

    #if DEBUG
    static func resetStartupForTests(didFinishLaunching: Bool = false) {
        guard FlowlightApp.runningTests else { return }
        self.didFinishLaunching = didFinishLaunching
        didStart = false
        startup = nil
    }
    #endif

    func applicationWillTerminate(_ notification: Notification) {
        // Not in tests (they share this process), and not in a demo or screenshot run: that is a throwaway instance
        // with its own database, and it must never strip the enforcement the real running app owns.
        guard !FlowlightApp.runningTests, !DemoData.isEnabled else { return }
        SettingsEnforcer.shared.relaxAll()
        UpdateLaunchPolicy.markCleanExit()
    }
}

@main
struct FlowlightApp: App {
    /// True while the XCTest bundle is being hosted by this app.
    static let runningTests = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @AppStorage(AnomalySettings.Keys.backgroundOnly) private var backgroundOnly = false

    /// `.accessory` drops the Dock icon and the Cmd-Tab entry, which is the point of running in the background.
    /// What it also drops is the menu bar: an accessory app never becomes the active application, so bringing a
    /// window forward left another app's name next to the Apple logo and Flowlight's own menus unreachable.
    ///
    /// So the policy follows the windows rather than the setting alone. While a window is open the app is
    /// `.regular` and owns the menu bar; once the last one closes it goes back to `.accessory` and leaves only
    /// the menu bar item behind.
    private static func applyActivationPolicy(backgroundOnly: Bool) {
        guard !runningTests else { return }
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        NSApp.setActivationPolicy(backgroundOnly && !hasWindow ? .accessory : .regular)
        if !backgroundOnly || hasWindow { NSApp.activate() }
    }

    /// Re-applies the policy after windows open or close, since the answer depends on how many are left.
    static func windowsChanged() {
        DispatchQueue.main.async {
            applyActivationPolicy(backgroundOnly: UserDefaults.standard.bool(forKey: AnomalySettings.Keys.backgroundOnly))
        }
    }

    @StateObject private var monitor: TrafficMonitor
    @StateObject private var extensionManager: ExtensionManager
    @StateObject private var nav: AppNavigation
    @StateObject private var updater: UpdateChecker
    @StateObject private var focus: FocusStore

    init() {
        let monitor = TrafficMonitor()
        let extensionManager = ExtensionManager()
        let nav = AppNavigation()
        let updater = UpdateChecker()
        let focus = FocusStore()
        _monitor = StateObject(wrappedValue: monitor)
        _extensionManager = StateObject(wrappedValue: extensionManager)
        _nav = StateObject(wrappedValue: nav)
        _updater = StateObject(wrappedValue: updater)
        _focus = StateObject(wrappedValue: focus)

        // SwiftUI may restore a background-only launch with no window and without rendering the menu-bar label yet.
        // Core services belong to the application lifecycle, not to either presentation path.
        guard !Self.runningTests else { return }
        AppDelegate.installStartup {
            monitor.start()
            monitor.applyFocus(focus.scope)
            extensionManager.refresh()
            extensionManager.matchExtensionToApp { check in
                guard check.repairing else { return }
                Task { @MainActor in monitor.extensionVersionRepairing(check) }
            }
            updater.start()
        }
    }

    var body: some Scene {
        WindowGroup("Flowlight", id: "main") {
            ContentView(rulePacks: monitor.rulePacks)
                .environmentObject(monitor)
                .environmentObject(extensionManager)
                .environmentObject(nav)
                .environmentObject(updater)
                .environmentObject(focus)
                .frame(minWidth: 1000, minHeight: 660)
                .onChange(of: backgroundOnly, initial: true) { _, on in Self.applyActivationPolicy(backgroundOnly: on) }
                .onAppear { Self.windowsChanged() }
                .onDisappear { Self.windowsChanged() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            SidebarCommands()
            CommandGroup(replacing: .appInfo) {
                Button(L("About Flowlight")) { AboutPanel.show() }
            }
            CommandGroup(after: .appInfo) {
                CheckForUpdatesButton().environmentObject(updater)
            }
            CommandGroup(replacing: .help) {
                // Help for wherever you are, first: someone who presses ⌘? on the Rules screen wants the part
                // about rules, not the top of a page they then have to search.
                Button(L("Help for %@", nav.selection.title)) { NSWorkspace.shared.open(Help.forScreen(nav.selection)) }
                    .keyboardShortcut("?", modifiers: .command)
                Button(L("Flowlight Help")) { NSWorkspace.shared.open(Help.base) }
                Button(L("Questions & Answers")) { NSWorkspace.shared.open(Help.faq) }
                Divider()
                Button(L("What Flowlight Reads on This Mac")) { NSWorkspace.shared.open(Help.agentConfiguration) }
                Button(L("Privacy")) { NSWorkspace.shared.open(Help.privacy) }
                Divider()
                Button(L("Report an Issue")) { NSWorkspace.shared.open(Help.issues) }
            }
            CommandGroup(before: .sidebar) {
                ForEach(SidebarItem.allCases) { item in
                    Button(item.title) { nav.show(item) }
                        .keyboardShortcut(item.shortcut ?? .init(" "), modifiers: item.shortcut == nil ? [] : .command)
                }
                Divider()
                Button(focus.isOn ? L("Turn Focus Off") : L("Turn Focus On")) { focus.isOn.toggle() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(focus.targets.isEmpty && !focus.isOn)
                Divider()
            }
        }

        Window(L("Software Update"), id: "update") {
            UpdateView().environmentObject(updater)
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)

        Window(L("Name Your Traffic"), id: "capture-onboarding") {
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
                .environmentObject(updater)
                .environmentObject(focus)
        } label: {
            MenuBarLabel()
                .environmentObject(monitor)
                .environmentObject(extensionManager)
                .environmentObject(updater)
                .environmentObject(focus)
        }

        Settings {
            SettingsView().environmentObject(monitor).environmentObject(updater)
        }
    }
}

struct MenuBarLabel: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var updater: UpdateChecker
    @EnvironmentObject var focus: FocusStore
    @Environment(\.openWindow) private var openWindow
    @AppStorage(AnomalySettings.Keys.backgroundOnly) private var backgroundOnly = false
    @AppStorage(AnomalySettings.Keys.menuBarRates) private var showRates = true

    var body: some View {
        label
            .onChange(of: focus.scope) { _, scope in monitor.applyFocus(scope) }
            .onChange(of: backgroundOnly, initial: true) { _, _ in FlowlightApp.windowsChanged() }
            // The menu bar item always exists, so a found update opens its window even with the main window closed.
            .onChange(of: updater.showWindow) { _, show in
                if show { openWindow(id: "update"); updater.showWindow = false }
            }
    }

    @ViewBuilder private var label: some View {
        if showRates {
            Text("↓\(ByteFormat.compact(monitor.currentIn)) ↑\(ByteFormat.compact(monitor.currentOut))")
                .monospacedDigit()
        } else {
            Image(systemName: monitor.unacknowledgedAlerts > 0 ? "exclamationmark.arrow.triangle.2.circlepath" : "arrow.up.arrow.down.circle")
        }
    }
}

/// "Check for Updates…" in the app menu and menu bar extra.
struct CheckForUpdatesButton: View {
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button(L("Check for Updates…")) {
            openWindow(id: "update")
            NSApp.activate()
            Task { await updater.check(userInitiated: true) }
        }
    }
}

/// The standard About panel, with the copyright from Info.plist and credits linking to the site, source and license.
enum AboutPanel {
    static func show() {
        let center = NSMutableParagraphStyle()
        center.alignment = .center
        center.paragraphSpacing = 4
        let body: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: center]
        func link(_ title: String, _ url: String) -> NSAttributedString {
            var attrs = body
            attrs[.link] = URL(string: url)
            return NSAttributedString(string: title, attributes: attrs)
        }
        let credits = NSMutableAttributedString(string: L("Every app. Every domain. Every agent.") + "\n", attributes: body)
        credits.append(link("flowlight.xinbetween.com", "https://flowlight.xinbetween.com"))
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        credits.append(link(L("Source code"), "https://github.com/xinbetween/flowlight"))
        credits.append(NSAttributedString(string: "  ·  ", attributes: body))
        credits.append(link(L("GPL-3.0 license"), "https://github.com/xinbetween/flowlight/blob/main/LICENSE"))
        credits.append(NSAttributedString(string: "\n" + L("This program comes with ABSOLUTELY NO WARRANTY. It is free software, and you are welcome to redistribute it under the terms of the GPL."), attributes: body))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }
}
