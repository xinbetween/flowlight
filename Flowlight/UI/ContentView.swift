import SwiftUI

struct ContentView: View {
    @ObservedObject private var localization = Localization.shared
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @EnvironmentObject var updater: UpdateChecker
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { nav.selection }, set: { if let v = $0 { nav.selection = v } })) {
                ForEach(SidebarSection.allCases) { section in
                    Section(section.title) {
                        ForEach(section.items) { item in
                            Label(item.title, systemImage: item.icon)
                                .badge(item == .alerts ? monitor.unacknowledgedAlerts : 0)
                                .tag(item)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .safeAreaInset(edge: .bottom) {
              VStack(spacing: 0) {
                if let update = updater.pendingUpdate {
                    Button { openWindow(id: "update") } label: {
                        Label("Flowlight \(update.version) is available", systemImage: "arrow.down.circle.fill")
                            .font(.caption.bold())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 10)
                    .help(L("See what's new and download the update"))
                }
                FocusBar()
                Button { nav.selection = .capture } label: {
                    HStack(alignment: .top, spacing: 8) {
                        LiveDot(color: monitor.isReceiving ? .green : .orange, active: monitor.isReceiving)
                            .padding(.top, 4)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(DemoData.isEnabled ? "Demo data" : monitor.mode == .networkExtension ? "Network Extension" : "nettop sampler")
                                .font(.caption.bold())
                            Text(monitor.status).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(10)
                .help(L("Capture source status — click to configure"))
                .accessibilityLabel("Capture status: \(monitor.status)")
              }
            }
        } detail: {
            Group {
                switch nav.selection {
                case .live: LiveView()
                case .agents: AgentsView()
                case .reports: ReportsView()
                case .alerts: AlertsView()
                case .rules: RulesView()
                case .inspect: InspectView()
                case .ask: AskView()
                case .devices: DevicesView()
                case .capture: CaptureView()
                }
            }
            // One help button for all nine screens, because the documentation is grouped the way this sidebar
            // is: whatever is on screen, the button opens the section about it rather than the top of the page.
            .toolbar {
                ToolbarItem {
                    Button { NSWorkspace.shared.open(Help.forScreen(nav.selection)) } label: {
                        Image(systemName: "questionmark.circle")
                    }
                    .help(L("Open the documentation for %@", nav.selection.title))
                    .accessibilityLabel(L("Help"))
                }
            }
        }
        .id(localization.revision)
        .onReceive(NotificationCenter.default.publisher(for: .flowlightOpenUpdate)) { _ in openWindow(id: "update") }
        .background(WindowSizer())
        .onAppear { monitor.windowAppeared() }
        .onDisappear { monitor.windowDisappeared() }
        .onChange(of: updater.showWindow) { _, show in
            if show { openWindow(id: "update"); updater.showWindow = false }
        }
        .onChange(of: monitor.showCaptureOnboarding, initial: true) { was, show in
            // A single Window scene, so several restored main windows don't compete to present it.
            if show { openWindow(id: "capture-onboarding") } else if was { dismissWindow(id: "capture-onboarding") }
        }
        .alert(L("Error"), isPresented: Binding(get: { monitor.lastError != nil }, set: { if !$0 { monitor.lastError = nil } })) {
            Button(L("OK")) { monitor.lastError = nil }
        } message: {
            Text(monitor.lastError ?? "")
        }
    }
}
