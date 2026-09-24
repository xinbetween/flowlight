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
        .toolbar { toolbar }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup {
            if store.isWatchingAnything {
                Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .help("Read the device list again now")
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

    private var content: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                if store.watchingBluetooth { bluetoothSection }
                if store.watchingUSB { usbSection }
                if !store.events.isEmpty { historySection }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
    }

    private var bluetoothSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if store.bluetooth.isEmpty {
                    Text("Nothing paired, or the list hasn't been read yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.bluetooth) { device in
                        DeviceRow(device: device)
                    }
                }
                Divider()
                Text("Paired devices and whether they're connected, read from the system every half minute. "
                     + "There are no byte counts here: macOS has no per-app accounting for Bluetooth, and the "
                     + "byte-level traces that would give one need Apple's PacketLogger profile, which an app can't read.")
                    .font(.caption).foregroundStyle(.secondary)
                if !store.bluetoothApps.isEmpty {
                    DisclosureGroup("\(store.bluetoothApps.count) apps are built to use Bluetooth") {
                        VStack(alignment: .leading, spacing: 3) {
                            ForEach(store.bluetoothApps) { app in
                                HStack(spacing: 6) {
                                    Text(app.name).font(.callout)
                                    Text(app.bluetoothPurpose ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            Text("This is each app saying so in its own Info.plist — who asked for Bluetooth, not who "
                                 + "macOS granted it to. That second list lives in a database an app can't read, and "
                                 + "Flowlight would rather name the difference than blur it.")
                                .font(.caption).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                        .padding(.top, 4)
                    }
                    .font(.caption)
                }
            }
        } label: {
            Label("Bluetooth · \(store.bluetooth.filter(\.connected).count) connected of \(store.bluetooth.count) paired",
                  systemImage: "dot.radiowaves.right")
        }
    }

    private var usbSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                if store.usb.isEmpty {
                    Text("Nothing attached, or the list hasn't been read yet.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(store.usb) { device in
                        DeviceRow(device: device)
                    }
                }
                Divider()
                Text("Devices attached over USB and volumes that appear, with the moment each arrived and left. "
                     + "Throughput isn't here for the same reason it isn't under Bluetooth: macOS doesn't account "
                     + "for it per app.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        } label: {
            Label("USB and external storage · \(store.usb.count)", systemImage: "cable.connector")
        }
    }

    private var historySection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(store.events.prefix(100)) { event in
                    HStack(spacing: 8) {
                        Image(systemName: event.kind.icon)
                            .foregroundStyle(.secondary).frame(width: 18)
                        Text(event.name).font(.callout).lineLimit(1)
                        Text(event.change.title)
                            .font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                        Text(event.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 8)
                        Text(event.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.caption).foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        } label: {
            Label("What changed", systemImage: "clock.arrow.circlepath")
        }
    }
}

private struct DeviceRow: View {
    let device: PeripheralDevice

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(device.connected ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
                .accessibilityLabel(device.connected ? "Connected" : "Not connected")
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).font(.callout).lineLimit(1)
                if !device.subtitle.isEmpty {
                    Text(device.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if device.capacity > 0 {
                Text(ByteFormat.string(device.capacity)).font(.caption).foregroundStyle(.secondary)
            }
            Text(device.id).font(.caption.monospaced()).foregroundStyle(.tertiary).lineLimit(1)
        }
    }
}
