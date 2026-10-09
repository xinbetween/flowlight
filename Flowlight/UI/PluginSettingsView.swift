import SwiftUI

struct PluginSettingsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var showClearConfirmation = false

    var body: some View {
        Form {
            Section {
                Text(L("Plugins add advisory findings to inspected exchanges. They do not block, rewrite, or send traffic anywhere by themselves."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            pluginSection(L("Official"), plugins: monitor.plugins.officialPlugins,
                          empty: L("No official plugins are installed."))
            pluginSection(L("Third-party"), plugins: monitor.plugins.thirdPartyPlugins,
                          empty: L("Third-party plugins are not installed in this version."))
            Section {
                Button(L("Clear plugin findings…"), role: .destructive) { showClearConfirmation = true }
                    .help(L("Delete retained plugin annotations without deleting recorded requests or plugin settings"))
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
        .confirmationDialog(L("Clear plugin findings?"), isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button(L("Clear findings"), role: .destructive) { monitor.clearPluginFindings() }
        } message: {
            Text(L("Recorded requests, response bodies, rules, guardrails, and plugin enable settings stay in place."))
        }
    }

    private func pluginSection(_ title: String, plugins: [PluginManifest], empty: String) -> some View {
        Section(title) {
            if plugins.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(plugins) { plugin in
                    PluginSettingsRow(plugin: plugin) { enabled in
                        monitor.plugins.setEnabled(plugin, enabled)
                    }
                }
            }
        }
    }
}

private struct PluginSettingsRow: View {
    var plugin: PluginManifest
    var setEnabled: (Bool) -> Void

    var body: some View {
        Toggle(isOn: Binding(get: { plugin.enabled }, set: setEnabled)) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(plugin.name).font(.callout.bold())
                    PluginPill(plugin.kind.title)
                    PluginPill(plugin.guardrailProvider.title)
                    if plugin.capabilities.contains(.suggestGuardrail) { PluginPill(L("Suggests guardrails")) }
                }
                Text(plugin.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Text(plugin.privacySummary).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                Text(L("%@ · v%@ · rule v%lld", plugin.publisher.title, plugin.version, plugin.ruleVersion))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .toggleStyle(.switch)
    }
}

private struct PluginPill: View {
    var text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(.quaternary.opacity(0.7), in: Capsule())
    }
}

private extension PluginManifest.Publisher {
    var title: String {
        switch self {
        case .official: return L("Official")
        case .thirdParty: return L("Third-party")
        }
    }
}
