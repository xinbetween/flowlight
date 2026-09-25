import SwiftUI

/// The channels that aren't the network.
///
/// A Mac sends and receives over more than TCP and UDP, and Flowlight was blind to the rest. This screen covers
/// what it can honestly cover: which devices are paired or attached, which apps are built to use them, and when
/// that changed. It does not report bytes, because macOS does not account for these per app and a number invented
/// here would be worse than no number.
struct DevicesView: View {
    @EnvironmentObject var monitor: TrafficMonitor

    var body: some View {
        DevicesContent(store: monitor.devices)
    }
}

private struct DevicesContent: View {
    @ObservedObject var store: DeviceStore

    var body: some View {
        Group {
            if store.isWatchingAnything {
                content
            } else {
                offer
            }
        }
        .navigationTitle("Devices")
        .navigationSubtitle(subtitle)
        .toolbar { toolbar }
    }

    /// Which channels are on, and how much of it is live. Both channels are off by default, so "nothing here" and
    /// "not watching" look the same on the screen — the title bar is where that difference can be stated once.
    private var subtitle: String {
        var on: [String] = []
        if store.watchingBluetooth { on.append("Bluetooth") }
        if store.watchingUSB { on.append("USB") }
        guard !on.isEmpty else { return "Not watching" }
        let live = store.bluetooth.filter(\.connected).count + store.usb.count
        let channels = on.joined(separator: " · ")
        return live == 0 ? "\(channels) · nothing connected" : "\(channels) · \(live) connected"
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if store.isWatchingAnything {
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .keyboardShortcut("r", modifiers: .command)
                    .help("Read the device list again now (⌘R)")
            }
            Menu {
                Toggle("Watch Bluetooth", isOn: Binding(get: { store.watchingBluetooth },
                                                        set: { store.watchingBluetooth = $0 }))
                Toggle("Watch USB and external storage", isOn: Binding(get: { store.watchingUSB },
                                                                       set: { store.watchingUSB = $0 }))
            } label: {
                Label("Channels", systemImage: "switch.2")
            }
            .help("Choose which channels Flowlight watches")
        }
    }

    /// Nothing is on yet. The offer says what each channel can and can't tell you before it is switched on, rather
    /// than after.
    private var offer: some View {
        ContentUnavailableView {
            Label("Nothing but the network is being watched", systemImage: "dot.radiowaves.left.and.right")
        } description: {
            Text("Bluetooth and USB are off until you turn them on. Neither needs a permission Flowlight doesn't "
                 + "already have — they're off because watching them widens what the app looks at, and that should "
                 + "be your decision rather than something an update did.\n\n"
                 + "Neither can report bytes. macOS keeps no per-app accounting for these channels, so what Flowlight "
                 + "can honestly show is what is connected, which apps are built to use it, and when that changed.")
        } actions: {
            Button("Watch Bluetooth") { store.watchingBluetooth = true }
            Button("Watch USB and external storage") { store.watchingUSB = true }
        }
    }

    // MARK: The screen

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                accounting
                if store.watchingBluetooth { bluetoothSection }
                if store.watchingUSB { usbSection }
                if !store.events.isEmpty { historySection }
            }
            .frame(maxWidth: 860, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity)
        }
    }

    /// The limit both channels share, said once at the top rather than twice further down. Someone arriving here
    /// from a screen full of byte counts will look for them, and the first thing the screen should do is explain
    /// why there aren't any.
    private var accounting: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "number").font(.caption)
            Text("No byte counts on these channels. macOS keeps no per-app accounting for Bluetooth or USB, so a "
                 + "figure here would be invented. What is honest is what's connected, which apps are built to use "
                 + "it, and when that changed.")
                .font(.caption)
            Spacer(minLength: 0)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10).padding(.vertical, 8)
        .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
    }

    // MARK: Bluetooth

    private var bluetoothSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(bluetoothHeading)
            card {
                if store.bluetooth.isEmpty {
                    placeholder("Nothing paired, or the list hasn't been read yet.")
                } else {
                    ForEach(Array(store.bluetooth.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider().padding(.leading, 50) }
                        DeviceRow(device: device).entrance()
                    }
                }
                if !store.bluetoothApps.isEmpty {
                    Divider()
                    bluetoothApps
                }
            }
            footnote("Paired devices and whether they're connected, read from the system every half minute. The "
                     + "byte-level traces that would give a throughput number need Apple's PacketLogger profile, "
                     + "which an app can't read.")
        }
    }

    private var bluetoothHeading: String {
        guard !store.bluetooth.isEmpty else { return "Bluetooth" }
        return "Bluetooth · \(store.bluetooth.filter(\.connected).count) connected of \(store.bluetooth.count) paired"
    }

    /// Who is built to use the radio. It sits folded away because it is a long list of apps that are merely
    /// capable — the devices above are the ones actually doing something.
    private var bluetoothApps: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 5) {
                ForEach(store.bluetoothApps) { app in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(app.name).font(.callout).lineLimit(1)
                        Text(app.bluetoothPurpose ?? "")
                            .font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                }
                Text("This is each app saying so in its own Info.plist — who asked for Bluetooth, not who macOS "
                     + "granted it to. That second list lives in a database an app can't read, and Flowlight would "
                     + "rather name the difference than blur it.")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 4)
            }
            .padding(.top, 8)
        } label: {
            Text("\(store.bluetoothApps.count) apps are built to use Bluetooth")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    // MARK: USB

    private var usbSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading(store.usb.isEmpty ? "USB and external storage"
                                      : "USB and external storage · \(store.usb.count) attached")
            card {
                if store.usb.isEmpty {
                    placeholder("Nothing attached, or the list hasn't been read yet.")
                } else {
                    ForEach(Array(store.usb.enumerated()), id: \.element.id) { index, device in
                        if index > 0 { Divider().padding(.leading, 50) }
                        DeviceRow(device: device).entrance()
                    }
                }
            }
            footnote("Devices attached over USB and volumes that appear, with the moment each arrived and left. "
                     + "Throughput isn't here for the same reason it isn't under Bluetooth: macOS doesn't account "
                     + "for it per app.")
        }
    }

    // MARK: What changed

    /// The history is the part of this screen that answers a question about the past, so it sits last and reads
    /// newest first — the same shape the rule feed has.
    private var historySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            heading("What changed")
            card {
                ForEach(Array(store.events.prefix(100).enumerated()), id: \.offset) { index, event in
                    if index > 0 { Divider().padding(.leading, 42) }
                    DeviceEventRow(event: event)
                }
            }
        }
        .entrance()
    }

    // MARK: Furniture

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .textCase(.uppercase)
            .padding(.leading, 2)
    }

    /// What the section can and can't tell you, under the section rather than inside it. It is worth reading once
    /// and not worth re-reading every time the list is scanned, and type that size says so.
    private func footnote(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 2)
    }

    private func placeholder(_ text: String) -> some View {
        Text(text)
            .font(.caption).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }
}

/// One device: what it is, what it says about itself, and whether it is live right now.
///
/// The name leads because that is what someone is looking for; what the device calls itself and its identifier sit
/// under it in monospace, because they are quoted from the device rather than written here. Connectedness is the
/// one thing that changes while the screen is open, so it gets the right-hand edge and the only moving part.
private struct DeviceRow: View {
    let device: PeripheralDevice

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            glyph
            VStack(alignment: .leading, spacing: 3) {
                Text(device.name)
                    .font(.body.weight(.medium)).lineLimit(1).truncationMode(.middle)
                HStack(spacing: 6) {
                    if !facts.isEmpty {
                        Text(facts).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                        Text("·").font(.caption).foregroundStyle(.quaternary)
                    }
                    Text(device.id)
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                        .help("How Flowlight recognises this device between sightings")
                }
            }
            Spacer(minLength: 8)
            state
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    private var glyph: some View {
        let tint: Color = device.connected ? .green : .secondary
        return Image(systemName: device.kind.icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 26, height: 26)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityHidden(true)
    }

    private var state: some View {
        HStack(spacing: 5) {
            LiveDot(color: device.connected ? .green : .secondary, active: device.connected, size: 6)
            Text(stateWord)
                .font(.caption)
                .foregroundStyle(device.connected ? HierarchicalShapeStyle.secondary : .tertiary)
        }
        .padding(.top, 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stateWord)
    }

    /// A paired speaker that is switched off and a drive that is plugged in are both "not doing anything", but
    /// only one of them is a state that changes — so each channel gets the word that is true for it.
    private var stateWord: String {
        switch device.kind {
        case .bluetooth: return device.connected ? "Connected" : "Not connected"
        case .usb: return "Attached"
        case .volume: return "Mounted"
        }
    }

    /// What the device says it is, and how big it is when that means anything.
    private var facts: String {
        var parts: [String] = []
        if !device.subtitle.isEmpty { parts.append(device.subtitle) }
        if device.capacity > 0 { parts.append(ByteFormat.string(device.capacity)) }
        return parts.joined(separator: " · ")
    }
}

/// One change in the history. The device is the subject, the change is the verb, and the clock sits where a clock
/// belongs — the same reading order as a rule decision in the feed.
private struct DeviceEventRow: View {
    let event: DeviceEvent

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: event.kind.icon)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(event.name).font(.callout).lineLimit(1)
                    Text(event.change.title)
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if !event.detail.isEmpty {
                    Text(event.detail)
                        .font(.caption.monospaced()).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text(when)
                .font(.caption.monospacedDigit()).foregroundStyle(.tertiary)
                .help(event.at.formatted(date: .complete, time: .standard))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// Most of the history is from today, and a column of identical dates is a column of noise. The day is said
    /// only where it isn't obvious, and the whole stamp is a hover away.
    private var when: String {
        let calendar = Calendar.current
        if calendar.isDateInToday(event.at) { return event.at.formatted(date: .omitted, time: .shortened) }
        if calendar.isDateInYesterday(event.at) {
            return "Yesterday \(event.at.formatted(date: .omitted, time: .shortened))"
        }
        return event.at.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private var tint: Color {
        switch event.change {
        case .connected: return .green
        case .disconnected: return .secondary
        case .appeared: return .blue
        case .removed: return .orange
        }
    }
}
