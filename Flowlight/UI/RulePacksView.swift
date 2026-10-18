import SwiftUI

struct RulePacksView: View {
    @EnvironmentObject var monitor: TrafficMonitor

    var body: some View {
        RulePacksContent(packs: monitor.rulePacks)
    }
}

private struct RulePackEditorRequest: Identifiable {
    let pack: RulePackDefinition
    let intent: RulePackEditorDraft.Intent
    var id: String { pack.id }
}

struct RulePackSaveTracker {
    private(set) var packIDs: Set<String> = []

    func contains(_ packID: String) -> Bool { packIDs.contains(packID) }
    mutating func begin(_ packID: String) { packIDs.insert(packID) }
    mutating func finish(_ packID: String) { packIDs.remove(packID) }
}

private struct RulePacksContent: View {
    @EnvironmentObject var monitor: TrafficMonitor
    @ObservedObject var packs: RulePackStore
    @State private var editor: RulePackEditorRequest?
    @State private var saves = RulePackSaveTracker()
    @State private var saveErrors: [String: String] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                explanation
                if packs.deliveryStats.droppedHits > 0 {
                    Label(L("%lld managed-pack decisions were omitted from activity because the extension's bounded queue was full.",
                            packs.deliveryStats.droppedHits), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(FL.warning)
                        .padding(10).background(FL.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                ForEach(packs.definitions) { pack in
                    card(pack)
                }
            }
            .padding(Measure.gutter)
        }
        .sheet(item: $editor) { request in
            RulePackEditor(pack: request.pack, saved: packs.configuration(for: request.pack.id),
                           intent: request.intent, packs: packs, rules: monitor.rules)
        }
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
        let configuration = packs.configuration(for: pack.id)
        let events = packs.events(for: pack.id)
        let blocks = events.reduce(0) { $0 + $1.count }
        let exceptions = packs.overrides(for: pack.id)
        let isSaving = saves.contains(pack.id)
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
                    if enabled {
                        saveErrors[pack.id] = nil
                        editor = RulePackEditorRequest(pack: pack, intent: .activate)
                    } else {
                        var changed = configuration
                        changed.enabled = false
                        saves.begin(pack.id)
                        saveErrors[pack.id] = nil
                        packs.save(changed) { success in
                            saves.finish(pack.id)
                            if !success { saveErrors[pack.id] = packs.failureMessage ?? L("Failed: %@", L("Save")) }
                        }
                    }
                })).toggleStyle(.switch).controlSize(.small).labelsHidden().disabled(isSaving)
            }
            HStack(spacing: 8) {
                pill(status(configuration), tint: statusTint(configuration))
                pill(configuration.scope == .allApps ? L("Every app") : L("%lld selected apps", configuration.apps.count))
                pill(L("%lld destinations", pack.entries.count))
                if blocks > 0 { pill(L("%lld blocked", blocks), tint: FL.critical) }
                if !exceptions.isEmpty {
                    pill(L("%lld exceptions", exceptions.count), tint: FL.good)
                }
                Spacer()
                Button(L("Review…")) {
                    saveErrors[pack.id] = nil
                    editor = RulePackEditorRequest(pack: pack, intent: .review)
                }.disabled(isSaving)
            }
            if let saveError = saveErrors[pack.id] {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.critical)
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
            switch packs.status {
            case .applying: return L("Applying…")
            case .failed: return L("Needs review")
            default: return L("Off")
            }
        }
        switch packs.status {
        case .off, .ready, .applying: return monitor.canBlock ? L("Applying…") : L("Watching only")
        case .enforcing: return monitor.canBlock ? L("Blocking") : L("Watching only")
        case .watchingOnly: return L("Watching only")
        case .incompatible: return L("Needs extension update")
        case .failed: return L("Needs review")
        }
    }

    private func statusTint(_ configuration: RulePackConfiguration) -> Color? {
        if !configuration.enabled {
            switch packs.status {
            case .applying, .failed: return FL.warning
            default: return nil
            }
        }
        return monitor.canBlock && packs.status == .enforcing ? FL.critical : FL.warning
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
    @ObservedObject var packs: RulePackStore
    @ObservedObject var rules: RuleStore
    @State private var draft: RulePackEditorDraft
    @State private var installed: [InstalledApps.App] = []
    @State private var appsLoaded = false
    @State private var appsScanned = false
    @State private var preview: RuleSimulation.Result?
    @State private var previewing = false
    @State private var previewError: String?
    @State private var saveError: String?
    @State private var confirmBroadening = false
    @State private var saving = false

    init(pack: RulePackDefinition, saved: RulePackConfiguration,
         intent: RulePackEditorDraft.Intent, packs: RulePackStore, rules: RuleStore) {
        self.pack = pack
        self.packs = packs
        self.rules = rules
        _draft = State(initialValue: RulePackEditorDraft(saved: saved, intent: intent))
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
            .disabled(saving)
            if let saveError {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.critical)
                    .padding(.horizontal, Measure.gutter).padding(.bottom, 8)
            }
            Divider()
            HStack {
                Button(L("Test against recent traffic")) { Task { await runPreview() } }
                    .disabled(previewing || saving)
                if previewing { ProgressView().controlSize(.small) }
                Spacer()
                Button(L("Cancel")) { dismiss() }.disabled(saving)
                Button(L("Save")) { save() }
                    .disabled(!draft.canSave || saving)
            }.padding(Measure.gutter)
        }
        .frame(width: Measure.prose)
        .frame(minHeight: 620)
        .interactiveDismissDisabled(saving)
        .onChange(of: draft.configuration) { _, _ in invalidatePreview() }
        .onChange(of: packs.version) { _, _ in invalidatePreview() }
        .onChange(of: rules.version) { _, _ in invalidatePreview() }
        .onAppear { loadApps() }
        .confirmationDialog(L("Apply this pack to every app?"), isPresented: $confirmBroadening) {
            Button(L("Apply to every app"), role: .destructive) { commit(draft.configuration) }
            Button(L("Cancel"), role: .cancel) {}
        } message: {
            Text(L("This broadens blocking from selected apps to every app on this Mac. Essential system traffic remains allowed."))
        }
    }

    private var scope: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L("Scope")).font(.headline)
            Picker("", selection: $draft.configuration.scope) {
                Text(L("Every app")).tag(RulePackConfiguration.Scope.allApps)
                Text(L("Only selected apps")).tag(RulePackConfiguration.Scope.selectedApps)
            }.pickerStyle(.segmented).labelsHidden()
            if draft.configuration.scope == .selectedApps {
                HStack {
                    TextField(L("App name, bundle identifier, or process"), text: $draft.typedApp)
                        .onSubmit { if appsLoaded { addApp() } }
                    if !appsScanned {
                        ProgressView().controlSize(.small)
                    } else if !appsLoaded {
                        Button(L("Refresh")) { loadApps() }.controlSize(.small)
                    }
                    Button(L("Add")) { addApp() }
                        .disabled(!appsLoaded || draft.typedApp.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if !draft.typedApp.isEmpty, !appSuggestions.isEmpty {
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
                    ForEach(draft.configuration.apps, id: \.self) { id in
                        Button { draft.configuration.apps.removeAll { $0 == id } } label: {
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
        if let previewError {
            Label(previewError, systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(FL.critical)
                .padding(10).background(FL.critical.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        } else if let preview {
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
        let found = packs.overrides(for: pack.id)
        if !found.isEmpty {
            DisclosureGroup(L("%lld exceptions", found.count)) {
                ForEach(found) { exception in
                    HStack {
                        Text(exception.app.isEmpty ? L("Every app") : exception.app).font(.caption)
                        Text("→").foregroundStyle(.tertiary)
                        Text(exception.host).font(.caption.monospaced())
                        Spacer()
                        Button(L("Delete"), role: .destructive) { packs.deleteOverride(exception) }
                    }.padding(.vertical, 2)
                }
            }
        }
    }

    private var appSuggestions: [InstalledApps.App] {
        Array(InstalledApps.search(draft.typedApp, in: installed).filter { candidate in
            !draft.configuration.apps.contains { $0.caseInsensitiveCompare(candidate.bundleID) == .orderedSame }
        }.prefix(5))
    }

    private func loadApps() {
        appsScanned = false
        appsLoaded = false
        Task {
            let result = await Task.detached(priority: .userInitiated) { InstalledApps.scan() }.value
            installed = result.apps
            appsLoaded = result.complete
            appsScanned = true
        }
    }

    private func addApp(_ value: String? = nil) {
        if let value { _ = draft.addApp(value, installed: installed, appsLoaded: appsLoaded) }
        else { _ = draft.submitApp(installed: installed, appsLoaded: appsLoaded) }
    }

    private func save() {
        saveError = nil
        switch draft.requestSave() {
        case .commit(let configuration): commit(configuration)
        case .confirmBroadening: confirmBroadening = true
        case nil: break
        }
    }

    private func commit(_ configuration: RulePackConfiguration? = nil) {
        saving = true
        saveError = nil
        let value = configuration ?? draft.configuration
        packs.save(value) { success in
            saving = false
            if success {
                dismiss()
            } else {
                saveError = packs.failureMessage ?? L("Failed: %@", L("Save"))
            }
        }
    }

    private func invalidatePreview() {
        preview = nil
        previewError = nil
    }

    private func runPreview() async {
        let candidate = draft.configuration
        let packVersion = packs.version
        let ruleVersion = rules.version
        previewing = true
        preview = nil
        previewError = nil
        defer { previewing = false }
        do {
            let input = try await monitor.read {
                (try $0.flowsForSimulation(since: Date().addingTimeInterval(-7 * 86400)),
                 try $0.loadPolicies())
            }
            guard candidate == draft.configuration,
                  packVersion == packs.version,
                  ruleVersion == rules.version else { return }
            preview = RulePackSimulation.run(candidate: candidate, definitions: packs.definitions,
                                             configurations: packs.configurations,
                                             overrides: packs.overrides, rules: rules.rules,
                                             policies: input.1, paused: rules.isPaused,
                                             flows: input.0, session: RuleStore.session)
        } catch {
            guard candidate == draft.configuration,
                  packVersion == packs.version,
                  ruleVersion == rules.version else { return }
            previewError = L("Failed: %@", L("Test against recent traffic"))
        }
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
