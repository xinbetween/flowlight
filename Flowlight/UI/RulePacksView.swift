import SwiftUI

struct RulePacksView: View {
    @EnvironmentObject var monitor: TrafficMonitor

    var body: some View {
        RulePacksContent(packs: monitor.rulePacks, catalog: monitor.rulePackCatalog)
    }
}

private struct RulePackEditorRequest: Identifiable {
    let pack: RulePackDefinition
    let receipt: RulePackReviewReceipt?
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
    @ObservedObject var catalog: RulePackCatalogUpdater
    @State private var editor: RulePackEditorRequest?
    @State private var saves = RulePackSaveTracker()
    @State private var saveErrors: [String: String] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                explanation
                officialUpdates
                if let failure = packs.failureMessage {
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(FL.warning)
                        .padding(10).background(FL.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if packs.deliveryStats.droppedHits > 0 {
                    Label(L("%lld managed-pack decisions were omitted from activity because the extension's bounded queue was full.",
                            packs.deliveryStats.droppedHits), systemImage: "exclamationmark.triangle")
                        .font(.caption).foregroundStyle(FL.warning)
                        .padding(10).background(FL.warning.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                }
                if catalog.status == .idle {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(L("Loading…")).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                } else {
                    ForEach(packs.definitions) { pack in
                        card(pack)
                    }
                    ForEach(packs.unavailableReviewConfigurations) { configuration in
                        unavailableCard(configuration)
                    }
                }
            }
            .padding(Measure.gutter)
        }
        .sheet(item: $editor) { request in
            RulePackEditor(pack: request.pack, receipt: request.receipt,
                           saved: packs.configuration(for: request.pack.id),
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

    private var officialUpdates: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Official pack updates")).font(.body.weight(.semibold))
                    Text(L("Flowlight checks its fixed HTTPS feed for publisher-signed destination lists. No traffic, pack settings, or device identifier is sent."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle(L("Automatic updates"), isOn: Binding(
                    get: { catalog.automaticRefresh },
                    set: { enabled in Task { await catalog.setAutomaticRefresh(enabled) } }
                ))
                .toggleStyle(.switch).controlSize(.small)
            }
            HStack(spacing: 8) {
                pill(catalogStatusText, tint: catalogStatusTint)
                if let sequence = catalog.receipt?.sequence { pill(L("Sequence %lld", sequence)) }
                Spacer()
                Button(L("Check Now")) { Task { await catalog.checkNow() } }
                    .disabled(catalog.status == .checking)
            }
            if let detail = catalogStatusDetail {
                Label(detail, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                if let success = catalog.catalogState.update.lastSuccess {
                    Text(L("Last verified %@", success.formatted(.relative(presentation: .named))))
                }
                if catalog.automaticRefresh,
                   let next = catalog.catalogState.update.nextEligibleAttempt {
                    Text(L("Next check %@", next.formatted(.relative(presentation: .named))))
                }
            }
            .font(.caption2).foregroundStyle(.tertiary)
            Text(L("Official source: %@", RulePackCatalogVerifier.sourceURL))
                .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                .textSelection(.enabled)
            if let receipt = catalog.receipt {
                Text(L("Publisher: Flowlight · signer %@ · catalog digest %@",
                       receipt.signerKeyID, String(receipt.digest.prefix(12))))
                    .font(.caption2.monospaced()).foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }

    private var catalogStatusText: String {
        switch catalog.status {
        case .idle: return L("Not checked yet")
        case .checking: return L("Checking…")
        case .current: return L("Verified and current")
        case .stale: return L("Verified last-known-good is stale")
        case .recovery: return L("Recovery required")
        case .failed(_, let usingLastKnownGood):
            return usingLastKnownGood ? L("Check failed · using last-known-good") : L("Check failed")
        }
    }

    private var catalogStatusTint: Color? {
        switch catalog.status {
        case .current: return FL.good
        case .checking, .idle: return nil
        case .stale, .recovery, .failed: return FL.warning
        }
    }

    private var catalogStatusDetail: String? {
        switch catalog.status {
        case .recovery(let message), .failed(let message, _): return message
        case .idle, .checking, .current, .stale: return nil
        }
    }

    private func card(_ pack: RulePackDefinition) -> some View {
        let configuration = packs.configuration(for: pack.id)
        let events = packs.events(for: pack.id)
        let blocks = events.reduce(0) { $0 + $1.count }
        let exceptions = packs.overrides(for: pack.id)
        let isSaving = saves.contains(pack.id)
        let activePeerName: String? = AdvertisingPackTierPolicy.exclusivePeer(of: pack.id).flatMap { peerID in
            guard packs.configuration(for: peerID).enabled else { return nil }
            return packs.definitions.first { $0.id == peerID }.map { L($0.manifest.titleKey) } ?? peerID
        }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: symbol(pack)).font(.title3).foregroundStyle(configuration.enabled ? FL.critical : .secondary)
                    .frame(width: 34, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(L(pack.manifest.titleKey)).font(.body.weight(.semibold))
                        if let badge = AdvertisingPackTierPolicy.localizedBadge(for: pack.id) {
                            pill(badge, tint: FL.accent)
                        }
                    }
                    Text(L(pack.manifest.summaryKey)).font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("", isOn: Binding(get: { configuration.enabled }, set: { enabled in
                    if enabled {
                        saveErrors[pack.id] = nil
                        editor = RulePackEditorRequest(pack: pack, receipt: packs.reviewReceipt(for: pack),
                                                       intent: .activate)
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
                pill(status(configuration, definition: pack), tint: statusTint(configuration, definition: pack))
                pill(configuration.scope == .allApps ? L("Every app") : L("%lld selected apps", configuration.apps.count))
                pill(L("%lld destinations", pack.entries.count))
                if blocks > 0 { pill(L("%lld blocked", blocks), tint: FL.critical) }
                if !exceptions.isEmpty {
                    pill(L("%lld exceptions", exceptions.count), tint: FL.good)
                }
                Spacer()
                Button(L("Review…")) {
                    saveErrors[pack.id] = nil
                    editor = RulePackEditorRequest(pack: pack, receipt: packs.reviewReceipt(for: pack),
                                                   intent: .review)
                }.disabled(isSaving)
            }
            if let saveError = saveErrors[pack.id] {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.critical)
            }
            if let activePeerName {
                Text(L("Enabling this pack replaces %@. The two Advertising tiers never stack.", activePeerName))
                    .font(.caption).foregroundStyle(FL.warning)
            }
            Text(L(pack.manifest.caveatKey)).font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            Text(catalog.isDownloadedUpdate(pack)
                 ? L("Official · Verified official update · pack v%@ · %@", pack.manifest.version, pack.manifest.license)
                 : L("Official · Bundled baseline · pack v%@ · %@", pack.manifest.version, pack.manifest.license))
                .font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(14)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 11))
    }

    private func unavailableCard(_ configuration: RulePackConfiguration) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "shippingbox.and.arrow.backward")
                    .font(.title3).foregroundStyle(FL.warning)
                    .frame(width: 34, height: 34).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Text(configuration.packID).font(.body.weight(.semibold)).textSelection(.enabled)
                    Text(L("This previously enabled official pack is no longer in the catalog. Blocking stopped automatically."))
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button(L("Acknowledge")) {
                    saves.begin(configuration.packID)
                    saveErrors[configuration.packID] = nil
                    packs.acknowledgeUnavailableReview(configuration.packID) { success in
                        saves.finish(configuration.packID)
                        if !success {
                            saveErrors[configuration.packID] = packs.failureMessage ?? L("Failed: %@", L("Save"))
                        }
                    }
                }
                .disabled(saves.contains(configuration.packID))
            }
            if let saveError = saveErrors[configuration.packID] {
                Label(saveError, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(FL.critical)
            }
        }
        .padding(14)
        .background(FL.warning.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
    }

    private func status(_ configuration: RulePackConfiguration,
                        definition: RulePackDefinition) -> String {
        if packs.needsReview(definition) { return L("Needs review") }
        if !configuration.enabled {
            return packs.status == .applying ? L("Applying…") : L("Off")
        }
        switch packs.status {
        case .off, .ready, .applying: return monitor.canBlock ? L("Applying…") : L("Watching only")
        case .enforcing: return monitor.canBlock ? L("Blocking") : L("Watching only")
        case .watchingOnly: return L("Watching only")
        case .incompatible: return L("Needs extension update")
        case .failed: return L("Apply failed")
        }
    }

    private func statusTint(_ configuration: RulePackConfiguration,
                            definition: RulePackDefinition) -> Color? {
        if packs.needsReview(definition) { return FL.warning }
        if !configuration.enabled {
            return packs.status == .applying ? FL.warning : nil
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

struct RulePackEditor: View {
    let pack: RulePackDefinition
    let receipt: RulePackReviewReceipt?
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
    @State private var pendingConfirmation: RulePackEditorDraft.Confirmation?
    @State private var pendingExclusivePeer: RulePackConfiguration?
    @State private var saving = false

    init(pack: RulePackDefinition, receipt: RulePackReviewReceipt?, saved: RulePackConfiguration,
         intent: RulePackEditorDraft.Intent, packs: RulePackStore, rules: RuleStore) {
        self.pack = pack
        self.receipt = receipt
        self.packs = packs
        self.rules = rules
        _draft = State(initialValue: RulePackEditorDraft(
            saved: saved,
            intent: intent,
            reviewedDefinition: pack,
            reviewReceipt: receipt
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(L(pack.manifest.titleKey)).font(.title3.weight(.semibold))
                    if let badge = AdvertisingPackTierPolicy.localizedBadge(for: pack.id) {
                        Text(badge).font(.caption2.weight(.semibold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(FL.accent.opacity(0.12), in: Capsule())
                            .accessibilityIdentifier("rule-pack-editor.\(pack.id).badge")
                    }
                }
                Text(L(pack.manifest.summaryKey)).font(.callout).foregroundStyle(.secondary)
            }.padding(Measure.gutter)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    scope
                    caveat
                    provenance
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
                Button(L("Cancel")) { dismiss() }
                    .disabled(saving)
                    .accessibilityIdentifier("rule-pack-editor.\(pack.id).cancel")
                Button(L("Save")) { save() }
                    .disabled(!draft.canSave || saving)
                    .accessibilityIdentifier("rule-pack-editor.\(pack.id).save")
            }.padding(Measure.gutter)
        }
        .frame(width: Measure.prose)
        .frame(minHeight: 620)
        .interactiveDismissDisabled(saving)
        .onChange(of: draft.configuration) { _, _ in invalidatePreview() }
        .onChange(of: packs.version) { _, _ in invalidatePreview() }
        .onChange(of: rules.version) { _, _ in invalidatePreview() }
        .onChange(of: monitor.dataVersion) { _, _ in invalidatePreview() }
        .onAppear { loadApps() }
        .confirmationDialog(
            confirmationTitle,
            isPresented: Binding(
                get: { pendingConfirmation != nil },
                set: {
                    if !$0 {
                        pendingConfirmation = nil
                        pendingExclusivePeer = nil
                    }
                }
            )
        ) {
            if let confirmation = pendingConfirmation {
                let expectedPeer = pendingExclusivePeer
                Button(confirmationButtonTitle(confirmation), role: .destructive) {
                    advance(confirmation, expectedExclusivePeer: expectedPeer)
                }
            }
            Button(L("Cancel"), role: .cancel) {
                pendingConfirmation = nil
                pendingExclusivePeer = nil
            }
        } message: {
            Text(confirmationMessage)
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
                        .onSubmit { addApp() }
                    if !appsScanned {
                        ProgressView().controlSize(.small)
                    } else if !appsLoaded {
                        Button(L("Refresh")) { loadApps() }.controlSize(.small)
                    }
                    Button(L("Add")) { addApp() }
                        .disabled(draft.typedApp.trimmingCharacters(in: .whitespaces).isEmpty)
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
        VStack(alignment: .leading, spacing: 6) {
            Label(L(pack.manifest.caveatKey), systemImage: "exclamationmark.circle")
            if AdvertisingPackTierPolicy.contains(pack.id) {
                Text(L("Hostname-layer blocking refuses every connection to a matched host; it cannot remove same-origin YouTube or Meta ads, page gaps, or browser overlays."))
                Text(L("Reviewed product, login, dashboard, and media surfaces stay reachable unless a dedicated advertising hostname is independently evidenced."))
            }
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        .padding(10).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityIdentifier("rule-pack-editor.\(pack.id).limitations")
    }

    private var provenance: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L("Signed pack provenance")).font(.headline)
            Text(L("Source: %@", pack.manifest.source))
            Text(L("Content digest: %@", pack.manifest.contentSHA256))
            Text(L("Official · pack v%@ · %@", pack.manifest.version, pack.manifest.license))
            if AdvertisingPackTierPolicy.contains(pack.id) {
                Text(L("Attribution: %@", "The EasyList authors · HaGeZi · Public Suffix List contributors"))
                Text(L("Source licenses: %@", "GPL-3.0-or-later · GPL-3.0 · MPL-2.0"))
            }
            if let receipt {
                Text(L("Catalog sequence %lld · digest %@", receipt.catalogSequence, receipt.catalogDigest))
            }
        }
        .font(.caption2.monospaced()).foregroundStyle(.tertiary)
        .textSelection(.enabled)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("rule-pack-editor.\(pack.id).provenance")
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
            LazyVStack(alignment: .leading, spacing: 3) {
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
                        Button(L("Delete"), role: .destructive) {
                            saving = true
                            saveError = nil
                            packs.deleteOverride(exception) { success in
                                saving = false
                                if !success {
                                    saveError = packs.failureMessage ?? L("Failed: %@", L("Delete"))
                                }
                            }
                        }
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
        let refresh = appsScanned
        appsScanned = false
        appsLoaded = false
        Task {
            let result = await Task.detached(priority: .userInitiated) { InstalledApps.scan(refresh: refresh) }.value
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
        let peer = packs.enabledExclusivePeer(for: pack.id)
        handle(
            draft.requestSave(exclusivePeerConfiguration: peer),
            expectedExclusivePeer: peer
        )
    }

    private func advance(_ confirmation: RulePackEditorDraft.Confirmation,
                         expectedExclusivePeer: RulePackConfiguration?) {
        pendingConfirmation = nil
        pendingExclusivePeer = nil
        handle(
            draft.confirm(confirmation, exclusivePeerConfiguration: expectedExclusivePeer),
            expectedExclusivePeer: expectedExclusivePeer
        )
    }

    private func handle(_ action: RulePackEditorDraft.SaveAction?,
                        expectedExclusivePeer: RulePackConfiguration?) {
        switch action {
        case .commit(let configuration, let receipt):
            commit(configuration, receipt: receipt, expectedExclusivePeer: expectedExclusivePeer)
        case .confirm(let confirmation):
            pendingConfirmation = confirmation
            pendingExclusivePeer = expectedExclusivePeer
        case nil:
            break
        }
    }

    private var confirmationTitle: String {
        switch pendingConfirmation {
        case .replacement(let peerID): return L("Replace %@?", peerName(peerID))
        case .aggressiveRisk: return L("Enable aggressive blocking?")
        case .broadening: return L("Apply this pack to every app?")
        case nil: return ""
        }
    }

    private var confirmationMessage: String {
        switch pendingConfirmation {
        case .replacement(let peerID):
            return L("Enabling this pack replaces %@. The two Advertising tiers never stack.", peerName(peerID))
        case .aggressiveRisk:
            return L("Aggressive coverage can break video, sign-in, checkout, or other content. Flowlight protects reviewed product surfaces, but hostname blocking cannot distinguish paths on a shared host.")
        case .broadening:
            return L("This broadens blocking from selected apps to every app on this Mac. Essential system traffic remains allowed.")
        case nil:
            return ""
        }
    }

    private func confirmationButtonTitle(_ confirmation: RulePackEditorDraft.Confirmation) -> String {
        switch confirmation {
        case .replacement(let peerID): return L("Replace %@", peerName(peerID))
        case .aggressiveRisk: return L("Enable aggressive blocking")
        case .broadening: return L("Apply to every app")
        }
    }

    private func peerName(_ packID: String) -> String {
        packs.definitions.first { $0.id == packID }.map { L($0.manifest.titleKey) } ?? packID
    }

    private func commit(_ configuration: RulePackConfiguration? = nil,
                        receipt: RulePackReviewReceipt? = nil,
                        expectedExclusivePeer: RulePackConfiguration?) {
        saving = true
        saveError = nil
        let value = configuration ?? draft.configuration
        packs.save(
            value,
            reviewedDefinition: pack,
            receipt: receipt,
            expectedExclusivePeer: expectedExclusivePeer
        ) { result in
            saving = false
            switch result {
            case .saved:
                dismiss()
            case .staleReview:
                saveError = L("This pack changed while it was open. Reopen it to review the new content before saving.")
            case .exclusivePeerChanged(let peer):
                handle(
                    draft.requestSave(exclusivePeerConfiguration: peer),
                    expectedExclusivePeer: peer
                )
            case .failed(let message):
                saveError = message
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
        let dataVersion = monitor.dataVersion
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
                  ruleVersion == rules.version,
                  dataVersion == monitor.dataVersion else { return }
            let definitions = packs.definitions
            let configurations = packs.configurations
            let overrides = packs.overrides
            let activeRules = rules.rules
            let paused = rules.isPaused
            let session = RuleStore.session
            let result = await Task.detached(priority: .userInitiated) {
                RulePackSimulation.run(candidate: candidate, definitions: definitions,
                                       configurations: configurations, overrides: overrides,
                                       rules: activeRules, policies: input.1, paused: paused,
                                       flows: input.0, session: session)
            }.value
            guard candidate == draft.configuration,
                  packVersion == packs.version,
                  ruleVersion == rules.version,
                  dataVersion == monitor.dataVersion else { return }
            preview = result
        } catch {
            guard candidate == draft.configuration,
                  packVersion == packs.version,
                  ruleVersion == rules.version,
                  dataVersion == monitor.dataVersion else { return }
            previewError = L("Failed: %@", String(describing: error))
        }
    }
}

enum RulePackActivityAction {
    static func exception(for event: RulePackEventRecord) -> RulePackOverride {
        RulePackOverride(packID: event.packID, app: event.bundleID,
                         host: event.matchedHost, match: event.match)
    }

    static func normalAllowRule(for event: RulePackEventRecord) -> Rule {
        Rule(action: .allow, app: event.bundleID, destination: event.matchedHost,
             destinationMatch: event.match == .exact ? .exact : .suffix)
    }
}

struct RulePackEventRow: View {
    let event: RulePackEventRecord
    @EnvironmentObject var monitor: TrafficMonitor
    @EnvironmentObject var nav: AppNavigation
    @State private var recentOverride: RulePackOverride?
    @State private var overrideSaving = false
    @State private var overrideError: String?

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
                        overrideSaving = true
                        overrideError = nil
                        monitor.rulePacks.deleteOverride(recentOverride) { success in
                            overrideSaving = false
                            if success { self.recentOverride = nil }
                            else { overrideError = monitor.rulePacks.failureMessage ?? L("Failed: %@", L("Delete")) }
                        }
                    }.buttonStyle(.link).font(.caption).disabled(overrideSaving)
                } else {
                    Menu {
                        Button(L("Allow for %@", event.appName)) { allowForApp() }
                        Button(L("Edit as normal rule…")) {
                            nav.writeRule(RulePackActivityAction.normalAllowRule(for: event))
                        }
                    } label: {
                        Text(L("Allow…"))
                    }
                    .menuStyle(.borderlessButton).fixedSize().font(.caption).disabled(overrideSaving)
                }
                if overrideSaving { ProgressView().controlSize(.mini) }
                if let overrideError {
                    Text(overrideError).font(.caption2).foregroundStyle(FL.critical)
                }
            }
        }.padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func allowForApp() {
        let exception = RulePackActivityAction.exception(for: event)
        overrideSaving = true
        overrideError = nil
        monitor.rulePacks.addOverride(exception) { success in
            overrideSaving = false
            if success { recentOverride = exception }
            else { overrideError = monitor.rulePacks.failureMessage ?? L("Failed: %@", L("Save")) }
        }
    }

    private var packName: String {
        monitor.rulePacks.definitions.first { $0.id == event.packID }.map { L($0.manifest.titleKey) } ?? event.packID
    }
}
