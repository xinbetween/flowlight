import Foundation

/// A device attached to this Mac by something other than the network: a Bluetooth peripheral, a USB device, a
/// volume that appeared.
///
/// Flowlight counts bytes for network traffic because macOS accounts for them per socket. It cannot do the same
/// here, and says so rather than implying a number it doesn't have: for these channels the honest scope is what is
/// connected, which apps are built to use it, and when that changed.
struct PeripheralDevice: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case bluetooth, usb, volume

        var title: String {
            switch self {
            case .bluetooth: return "Bluetooth"
            case .usb: return "USB"
            case .volume: return "External storage"
            }
        }

        var icon: String {
            switch self {
            case .bluetooth: return "dot.radiowaves.right"
            case .usb: return "cable.connector"
            case .volume: return "externaldrive"
            }
        }
    }

    var kind: Kind
    /// Stable across sightings: a Bluetooth address, a USB serial or location id, a volume path.
    var id: String
    var name: String
    /// What it is, in the device's own words — "Headphones", "Keyboard", "Mass Storage".
    var detail: String
    var connected: Bool
    /// Who makes it, when the device says.
    var vendor: String = ""
    /// Capacity in bytes, for a volume. Zero elsewhere.
    var capacity: Int64 = 0

    var subtitle: String {
        [detail, vendor].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// One change worth recording: something connected, disconnected, or was seen for the first time.
struct DeviceEvent: Identifiable, Equatable, Sendable {
    enum Change: String, Sendable {
        case appeared, connected, disconnected, removed

        var title: String {
            switch self {
            case .appeared: return "Paired"
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            case .removed: return "Unpaired"
            }
        }
    }

    var id: Int64 = 0
    var at: Date
    var kind: PeripheralDevice.Kind
    var deviceID: String
    var name: String
    var detail: String
    var change: Change
}

/// What changed between two sightings of the same channel.
///
/// A pure function over two lists, so the part that decides what counts as an event can be tested without a Mac
/// with anything plugged into it.
enum DeviceDiff {
    static func events(from old: [PeripheralDevice], to new: [PeripheralDevice], at now: Date = Date(),
                       firstSighting: Bool = false) -> [DeviceEvent] {
        // The first sighting is a baseline, not a flurry of "connected" notices for everything already attached.
        guard !firstSighting else { return [] }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let after = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var events: [DeviceEvent] = []
        for device in new {
            guard let was = before[device.id] else {
                events.append(DeviceEvent(at: now, kind: device.kind, deviceID: device.id, name: device.name,
                                          detail: device.subtitle, change: device.connected ? .connected : .appeared))
                continue
            }
            if was.connected != device.connected {
                events.append(DeviceEvent(at: now, kind: device.kind, deviceID: device.id, name: device.name,
                                          detail: device.subtitle,
                                          change: device.connected ? .connected : .disconnected))
            }
        }
        for device in old where after[device.id] == nil {
            events.append(DeviceEvent(at: now, kind: device.kind, deviceID: device.id, name: device.name,
                                      detail: device.subtitle, change: .removed))
        }
        return events.sorted { $0.name < $1.name }
    }
}
