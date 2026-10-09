import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct PluginSettingsView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var showClearConfirmation = false
    @State private var message: String?
    @State private var configuring: PluginManifest?
    @State private var removing: PluginManifest?

    var body: some View {
        Form {
            Section {
                Text(L("Plugins add advisory findings to inspected exchanges. They do not block, rewrite, or send traffic anywhere by themselves."))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button(L("Import Package…"), action: importPackage)
                    Button(L("Backfill Findings")) { backfill(nil) }
                    Button(L("Clear plugin findings…"), role: .destructive) { showClearConfirmation = true }
                }
                if let message {
                    Text(message).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text(L("Import reads a local plugin manifest package and stores it as installed metadata. Until sandboxed plugins ship, installed packages are visible and configurable but only Flowlight built-ins create findings."))
                    .font(.caption).foregroundStyle(.secondary)
            }
            pluginSection(L("Official"), plugins: monitor.plugins.officialPlugins,
                          empty: L("No official plugins are installed."))
            pluginSection(L("Third-party"), plugins: monitor.plugins.thirdPartyPlugins,
                          empty: L("No third-party plugin packages are installed."))
        }
        .formStyle(.grouped)
        .frame(height: 620)
        .confirmationDialog(L("Clear plugin findings?"), isPresented: $showClearConfirmation, titleVisibility: .visible) {
            Button(L("Clear findings"), role: .destructive) { monitor.clearPluginFindings() }
        } message: {
            Text(L("Recorded requests, response bodies, rules, guardrails, and plugin enable settings stay in place."))
        }
        .confirmationDialog(L("Remove installed plugin?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            if let plugin = removing {
                Button(L("Remove %@", plugin.name), role: .destructive) {
                    monitor.plugins.removeInstalled(plugin)
                    removing = nil
                }
            }
        } message: {
            if let plugin = removing {
                Text(L("%@ and its retained findings will be removed. Built-in plugins cannot be removed.", plugin.name))
            }
        }
        .sheet(item: $configuring) { plugin in
            PluginConfigurationSheet(plugin: plugin) { configuration in
                monitor.plugins.updateConfiguration(plugin, configuration: configuration)
                message = L("Saved configuration for %@.", plugin.name)
            }
        }
    }

    private func pluginSection(_ title: String, plugins: [PluginManifest], empty: String) -> some View {
        Section(title) {
            if plugins.isEmpty {
                Text(empty).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(plugins) { plugin in
                    PluginSettingsRow(plugin: plugin, setEnabled: { enabled in
                        monitor.plugins.setEnabled(plugin, enabled)
                    }, configure: {
                        configuring = plugin
                    }, exportPackage: {
                        exportPackage(plugin)
                    }, backfill: {
                        backfill(plugin)
                    }, remove: plugin.source == .installed ? {
                        removing = plugin
                    } : nil)
                }
            }
        }
    }

    private func importPackage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = L("Import")
        panel.message = L("Choose a Flowlight inspection plugin manifest or package JSON file.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            monitor.plugins.importPackage(data: data) { result in
                switch result {
                case .success(let imported): message = L("Installed %@.", imported.manifest.name)
                case .failure(let error): message = L("Import failed: %@", error.localizedDescription)
                }
            }
        } catch {
            message = L("Import failed: %@", error.localizedDescription)
        }
    }

    private func exportPackage(_ plugin: PluginManifest) {
        do {
            let data = try monitor.plugins.exportPackage(plugin)
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.nameFieldStringValue = "\(plugin.id)-plugin.json"
            if panel.runModal() == .OK, let url = panel.url {
                try data.write(to: url, options: .atomic)
                message = L("Exported %@.", plugin.name)
            }
        } catch {
            message = L("Export failed: %@", error.localizedDescription)
        }
    }

    private func backfill(_ plugin: PluginManifest?) {
        monitor.plugins.backfill(plugin) { result in
            switch result {
            case .success(let result):
                message = plugin.map { L("Backfilled %@: %lld findings.", $0.name, result.findingCount) }
                    ?? L("Backfilled built-in plugins: %lld findings.", result.findingCount)
            case .failure(let error): message = L("Backfill failed: %@", error.localizedDescription)
            }
        }
    }
}

private struct PluginSettingsRow: View {
    var plugin: PluginManifest
    var setEnabled: (Bool) -> Void
    var configure: () -> Void
    var exportPackage: () -> Void
    var backfill: () -> Void
    var remove: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(isOn: Binding(get: { plugin.enabled }, set: setEnabled)) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(plugin.name).font(.callout.bold())
                        PluginPill(plugin.kind.title)
                        PluginPill(plugin.guardrailProvider.title)
                        PluginPill(plugin.source.title)
                        if plugin.capabilities.contains(.suggestGuardrail) { PluginPill(L("Suggests guardrails")) }
                    }
                    Text(plugin.description).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Text(plugin.privacySummary).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    Text(L("%@ · v%@ · rule v%lld", plugin.publisher.title, plugin.version, plugin.ruleVersion))
                        .font(.caption2).foregroundStyle(.tertiary)
                    if !plugin.configuration.isEmpty {
                        Text(L("Configured: %@", plugin.configuration.keys.sorted().joined(separator: ", ")))
                            .font(.caption2).foregroundStyle(.tertiary)
                    }
                }
            }
            .toggleStyle(.switch)
            HStack(spacing: 8) {
                Button(L("Configure…"), action: configure)
                Button(L("Export…"), action: exportPackage)
                Button(L("Backfill"), action: backfill)
                if let remove { Button(L("Remove"), role: .destructive, action: remove) }
            }
            .font(.caption)
        }
        .padding(.vertical, 2)
    }
}

private struct PluginConfigurationSheet: View {
    @Environment(\.dismiss) private var dismiss
    var plugin: PluginManifest
    var save: ([String: String]) -> Void
    @State private var rows: [ConfigurationRow]

    init(plugin: PluginManifest, save: @escaping ([String: String]) -> Void) {
        self.plugin = plugin
        self.save = save
        _rows = State(initialValue: plugin.configuration.sorted { $0.key < $1.key }.map { ConfigurationRow(key: $0.key, value: $0.value) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("Configure %@", plugin.name)).font(.headline)
            Text(L("Configuration is stored locally as string key/value metadata. It does not grant a plugin network, file, or traffic mutation access."))
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach($rows) { $row in
                        HStack(spacing: 8) {
                            TextField(L("Key"), text: $row.key).textFieldStyle(.roundedBorder)
                            TextField(L("Value"), text: $row.value).textFieldStyle(.roundedBorder)
                            Button { rows.removeAll { $0.id == row.id } } label: { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless).help(L("Remove this setting"))
                        }
                    }
                }
            }
            HStack {
                Button(L("Add Setting")) { rows.append(ConfigurationRow()) }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) {
                    save(Dictionary(uniqueKeysWithValues: rows.compactMap { row in
                        let key = row.key.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !key.isEmpty else { return nil }
                        return (key, row.value)
                    }))
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520, height: 360)
    }

    private struct ConfigurationRow: Identifiable {
        let id = UUID()
        var key = ""
        var value = ""
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

private extension PluginManifest.Source {
    var title: String {
        switch self {
        case .builtIn: return L("Built-in")
        case .installed: return L("Installed")
        }
    }
}
