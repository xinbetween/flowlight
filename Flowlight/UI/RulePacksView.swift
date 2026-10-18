import SwiftUI

struct RulePacksView: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @State private var editor: RulePackDefinition?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                explanation
                if monitor.rulePacks.deliveryStats.droppedHits > 0 {
                    Label(L("%lld managed-pack decisions were omitted from activity because the extension's bounded queue was full.",
                            monitor.rulePacks.deliveryStats.droppedHits), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(FL.warning)
                        .padding(10).background(FL.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(monitor.rulePacks.definitions) { pack in
                    card(pack)
                }
            }
            .padding(Measure.gutter)
        }
        .sheet(item: $editor) { pack in RulePackEditor(pack: pack) }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("Network ad and tracker blocking")).font(.headline)
            Text(L("Official packs refuse connections to known destinations across apps. They are off until you enable them and need the Network Extension; they cannot remove page layout gaps, browser overlays, scripted popups, or native app windows."))
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    private func card(_ pack: RulePackDefinition) -> some View {
        let configuration = monitor.rulePacks.configuration(for: pack.id)
        let events = monitor.rulePacks.events(for: pack.id)
        let blocks = events.reduce(0) { $0 + $1.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(pack)).font(.title3).foregroundStyle(configuration.enabled ? FL.critical : .secondary)
                    .frame(width: 34, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(L(pack.manifest.titleKey)).font(.body.weight(.semibold))
                    Text(L(pack.manifest.summaryKey)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { configuration.enabled }, set: { enabled in
                    if enabled { editor = pack }
                    else { var changed = configuration; changed.enabled = false; monitor.rulePacks.save(changed) }
                })).toggleStyle(.switch).controlSize(.small).labelsHidden()
            }
            HStack(spacing: 8) {
                pill(status(configuration), tint: statusTint(configuration))
                pill(configuration.scope == .allApps ? L("Every app") : L("%lld selected apps", configuration.apps.count))
                pill(L("%lld destinations", pack.entries.count))
                if blocks > 0 { pill(L("%lld blocked", blocks), tint: FL.critical) }
                if !monitor.rulePacks.overrides(for: pack.id).isEmpty {
                    pill(L("%lld exceptions", monitor.rulePacks.overrides(for: pack.id).count), tint: FL.good)
                }
                Spacer()
                Button(L("Review…")) { editor = pack }
            }
            Text(L(pack.manifest.caveatKey)).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(L("Official · Built into Flowlight · pack v%@ · %@", pack.manifest.version, pack.manifest.license))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }

    private func status(_ configuration: RulePackConfiguration) -> String {
        if !configuration.enabled {
            switch monitor.rulePacks.status {
            case .applying: return L("Applying…")
            case .failed: return L("Needs review")
            default: return L("Off")
            }
        }
        switch monitor.rulePacks.status {
        case .off, .ready, .applying: return monitor.canBlock ? L("Applying…") : L("Watching only")
        case .enforcing: return monitor.canBlock ? L("Blocking") : L("Watching only")
        case .watchingOnly: return L("Watching only")
        case .incompatible: return L("Needs extension update")
        case .failed: return L("Needs review")
        }
    }

    private func statusTint(_ configuration: RulePackConfiguration) -> Color? {
        if !configuration.enabled {
            switch monitor.rulePacks.status {
            case .applying, .failed: return FL.warning
            default: return nil
            }
        }
        return monitor.canBlock && monitor.rulePacks.status == .enforcing ? FL.critical : FL.warning
    }

    private func symbol(_ pack: RulePackDefinition) -> String {
        switch pack.entries.first?.category {
        case .advertising: return "rectangle.badge.xmark"
        case .tracking: return "point.3.connected.trianglepath.dotted"
        case .telemetry: return "chart.bar.xaxis"
        case nil: return "shield"
        }
    }

    private func pill(_ text: String, tint: Color? = nil) -> some View {
        Text(text).font(.caption2.weight(.medium)).foregroundStyle(tint ?? .secondary)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background((tint ?? Color.secondary).opacity(0.12), in: Capsule())
    }
}

private struct RulePackEditor: View {
    let pack: RulePackDefinition
    @EnvironmentObject var monitor: TrafficMonitor
    @Environment(\.dismiss) private var dismiss
    @State private var configuration: RulePackConfiguration
    @State private var originalConfiguration: RulePackConfiguration
    @State private var app = ""
    @State private var installed: [InstalledApps.App] = []
    @State private var preview: RuleSimulation.Result?
    @State private var previewing = false
    @State private var confirmBroadening = false

    init(pack: RulePackDefinition) {
        self.pack = pack
        let initial = RulePackConfiguration(packID: pack.id)
        _configuration = State(initialValue: initial)
        _originalConfiguration = State(initialValue: initial)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text(L(pack.manifest.titleKey)).font(.title3.weight(.semibold))
                Text(L(pack.manifest.summaryKey)).font(.callout).foregroundStyle(.secondary)
            }.padding(Measure.gutter)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scope
                    caveat
                    previewSection
                    destinations
                    exceptions
                }.padding(Measure.gutter)
            }
            Divider()
            HStack {
                Button(L("Test against recent traffic")) { Task { await runPreview() } }
                if previewing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { dismiss() }
                Button(L("Save")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(configuration.scope == .selectedApps && configuration.apps.isEmpty)
            }.padding(Measure.gutter)
        }
        .frame(width: Measure.prose)
        .frame(minHeight: 620)
        .onAppear {
            let saved = monitor.rulePacks.configuration(for: pack.id)
            configuration = saved
            if !saved.enabled { configuration.enabled = true }
            originalConfiguration = saved
            Task { installed = await Task.detached(priority: .userInitiated) { InstalledApps.all() }.value }
        }
        .confirmationDialog(L("Apply this pack to every app?"), isPresented: $confirmBroadening) {
            Button(L("Apply to every app"), role: .destructive) { commit() }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This broadens blocking from selected apps to every app on this Mac. Essential system traffic remains allowed."))
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Scope")).font(.headline)
            Picker("", selection: $configuration.scope) {
                Text(L("Every app")).tag(RulePackConfiguration.Scope.allApps)
                Text(L("Only selected apps")).tag(RulePackConfiguration.Scope.selectedApps)
            }.pickerStyle(.segmented).labelsHidden()
            if configuration.scope == .selectedApps {
                HStack {
                    TextField(L("App name, bundle identifier, or process"), text: $app)
                    Button(L("Add")) { addApp() }.disabled(app.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !app.isEmpty, !appSuggestions.isEmpty {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(appSuggestions) { suggestion in
                            Button {
                                addApp(suggestion.bundleID)
                            } label: {
                                HStack(spacing: 7) {
                                    AppIconView(path: suggestion.path, size: 16)
                                    Text(suggestion.name).font(.callout)
                                    Text(suggestion.bundleID).font(.caption.monospaced())
                                        .foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                }
                                .contentShape(Rectangle())
                                .padding(.vertical, 3)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                FlowLayout(spacing: 6) {
                    ForEach(configuration.apps, id: \.self) { id in
                        Button { configuration.apps.removeAll { $0 == id } } label: {
                            Label(id, systemImage: "xmark.circle.fill").font(.caption)
                        }.buttonStyle(.borderless)
                    }
                }
            }
        }
    }

    private var caveat: some View {
        Label(L(pack.manifest.caveatKey), systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder private var previewSection: some View {
        if let preview {
            VStack(alignment: .leading, spacing: 5) {
                Text(L("Recent-traffic impact")).font(.headline)
                if preview.connectionsConsidered == 0 {
                    Text(L("No retained traffic was available to test.")).font(.caption).foregroundStyle(.secondary)
                } else if preview.isEmpty {
                    Text(L("Would have changed nothing across %lld retained connections.", preview.connectionsConsidered))
                        .font(.caption).foregroundStyle(FL.good)
                } else {
                    Text(L("Would have refused %lld of %lld connections from %lld apps (%@).",
                           preview.connectionsRefused, preview.connectionsConsidered, preview.appsAffected,
                           ByteFormat.string(preview.bytesRefused))).font(.caption)
                    ForEach(preview.refusals.prefix(8)) { change in
                        HStack { Text(change.appName); Text(change.destination).font(.caption.monospaced()).foregroundStyle(.secondary); Spacer(); Text(L("%lld×", change.connections)).font(.caption) }
                    }
                }
            }
        }
    }

    private var destinations: some View {
        DisclosureGroup(L("%lld destinations", pack.entries.count)) {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(pack.entries) { entry in
                    Text(entry.host).font(.caption.monospaced()).textSelection(.enabled)
                }
            }.padding(.top, 6)
        }
    }

    @ViewBuilder private var exceptions: some View {
        let found = monitor.rulePacks.overrides(for: pack.id)
        if !found.isEmpty {
            DisclosureGroup(L("%lld exceptions", found.count)) {
                ForEach(found) { exception in
                    HStack {
                        Text(exception.app.isEmpty ? L("Every app") : exception.app).font(.caption)
                        Text("→").foregroundStyle(.tertiary)
                        Text(exception.host).font(.caption.monospaced())
                        Spacer()
                        Button(L("Delete"), role: .destructive) { monitor.rulePacks.deleteOverride(exception) }
                    }.padding(.vertical, 2)
                }
            }
        }
    }

    private var appSuggestions: [InstalledApps.App] {
        Array(InstalledApps.search(app, in: installed).filter { candidate in
            !configuration.apps.contains { $0.caseInsensitiveCompare(candidate.bundleID) == .orderedSame }
        }.prefix(5))
    }

    private func addApp(_ value: String? = nil) {
        guard let target = InstalledApps.target(forTyped: value ?? app, apps: installed) else { return }
        if !configuration.apps.contains(where: { $0.caseInsensitiveCompare(target.value) == .orderedSame }) {
            configuration.apps.append(target.value); configuration.apps.sort()
        }
        app = ""
    }

    private func save() {
        if originalConfiguration.enabled,
           originalConfiguration.scope == .selectedApps,
           configuration.scope == .allApps {
            confirmBroadening = true
        } else {
            commit()
        }
    }

    private func commit() {
        monitor.rulePacks.save(configuration)
        dismiss()
    }

    private func runPreview() async {
        previewing = true
        defer { previewing = false }
        let input = try? await monitor.read {
            (try $0.flowsForSimulation(since: Date().addingTimeInterval(-7 * 86400)), try $0.loadPolicies())
        }
        preview = RulePackSimulation.run(candidate: configuration, definitions: monitor.rulePacks.definitions,
                                         configurations: monitor.rulePacks.configurations,
                                         overrides: monitor.rulePacks.overrides, rules: monitor.rules.rules,
                                         policies: input?.1 ?? [:], paused: monitor.rules.isPaused,
                                         flows: input?.0 ?? [], session: RuleStore.session)
    }
}

struct RulePackEventRow: View {
    let event: RulePackEventRecord
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @State private var recentOverride: RulePackOverride?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "rectangle.badge.xmark").font(.caption).foregroundStyle(FL.critical)
                .frame(width: 14).padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(event.host):\(event.port)").font(.callout.monospaced()).lineLimit(1)
                Text(L("%@ · %@ pack v%@ matched %@ · %lld connections",
                       event.appName, packName, event.packVersion, event.matchedHost, event.count))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(event.lastAt.formatted(date: .omitted, time: .standard)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                if let recentOverride {
                    Button(L("Undo")) {
                        monitor.rulePacks.deleteOverride(recentOverride)
                        self.recentOverride = nil
                    }.buttonStyle(.link).font(.caption)
                } else {
                    Menu {
                        Button(L("Allow for %@", event.appName)) { allowForApp() }
                        Button(L("Edit as normal rule…")) {
                            nav.writeRule(Rule(action: .allow, app: event.bundleID, destination: event.matchedHost))
                        }
                    } label: {
                        Text(L("Allow…"))
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption)
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func allowForApp() {
        let exception = RulePackOverride(packID: event.packID, app: event.bundleID,
                                         host: event.matchedHost, match: event.match)
        recentOverride = exception
        monitor.rulePacks.addOverride(exception)
    }

    private var packName: String {
        monitor.rulePacks.definitions.first { $0.id == event.packID }.map { L($0.manifest.titleKey) } ?? event.packID
    }
}
