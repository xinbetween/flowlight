import Foundation

protocol PeripheralMonitoring: AnyObject {
    var onDevices: ([PeripheralDevice], UInt64) -> Void { get set }
    var onEvents: ([DeviceEvent], UInt64) -> Void { get set }
    func start(generation: UInt64)
    func stop()
    func refresh()
}

/// What is paired to this Mac over Bluetooth, and when that changes.
///
/// **What this can and can't say.** macOS keeps no per-app byte accounting for Bluetooth: there is no equivalent of
/// the per-socket counters the network side is built on, and byte-level HCI traces need Apple's PacketLogger
/// profile, which an ordinary app cannot read. So Flowlight reports which devices are paired, which are connected,
/// and when that changed — and it does not pretend to know how much any app sent over the radio.
///
/// It reads `system_profiler SPBluetoothDataType`, which needs no entitlement and no permission prompt, and covers
/// both Classic and Low Energy devices. That costs a subprocess of a second or so, which is why it is polled every
/// half minute rather than continuously, and only while the feature is switched on.
final class BluetoothMonitor: PeripheralMonitoring, @unchecked Sendable {
    /// Called with the current devices whenever the list is re-read, and separately with anything that changed.
    var onDevices: ([PeripheralDevice], UInt64) -> Void = { _, _ in }
    var onEvents: ([DeviceEvent], UInt64) -> Void = { _, _ in }

    private let queue = DispatchQueue(label: "flowlight.bluetooth", qos: .utility)
    private let lifecycle = PeripheralMonitorLifecycle()
    private var timer: DispatchSourceTimer?
    private var known: [PeripheralDevice] = []
    private var sawAnything = false
    private var running = false
    private var generation: UInt64 = 0

    var interval: TimeInterval = 30
    /// Overridable for tests. Production reads use the cancellable subprocess owned by `lifecycle`.
    var read: (() -> Data?)?

    func start(generation: UInt64) {
        lifecycle.requestStart(generation: generation)
        queue.async { [weak self] in
            guard let self, self.lifecycle.isCurrent(generation) else { return }
            self.stopLocked()
            self.generation = generation
            self.running = true
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: self.interval, leeway: .seconds(5))
            timer.setEventHandler { [weak self] in self?.sample() }
            timer.resume()
            self.timer = timer
        }
    }

    func stop() {
        lifecycle.requestStop()
        queue.async { [self] in stopLocked() }
    }

    private func stopLocked() {
        running = false
        timer?.cancel()
        timer = nil
        known = []
        sawAnything = false
    }

    /// Re-reads now, for the button that says so.
    func refresh() { queue.async { [weak self] in self?.sample() } }

    private func sample() {
        let sampleGeneration = generation
        guard running, lifecycle.isCurrent(sampleGeneration) else { return }
        let data: Data?
        if let read {
            data = read()
        } else {
            data = lifecycle.runSystemProfiler(
                arguments: ["SPBluetoothDataType", "-json"],
                generation: sampleGeneration
            )
        }
        guard running,
              lifecycle.isCurrent(sampleGeneration),
              let data,
              let devices = Self.parse(data) else { return }
        let events = DeviceDiff.events(from: known, to: devices, firstSighting: !sawAnything)
        known = devices
        sawAnything = true
        onDevices(devices, sampleGeneration)
        if !events.isEmpty { onEvents(events, sampleGeneration) }
    }

    // MARK: Reading what it said

    /// `system_profiler SPBluetoothDataType -json`, as a list of devices.
    ///
    /// The shape is awkward: connected and disconnected devices are two separate arrays, and each entry is a
    /// single-key dictionary whose key is the device's name. Parsed rather than assumed, so a Mac with no
    /// Bluetooth hardware, or a macOS that renames a key, produces an empty list instead of a crash.
    static func parse(_ data: Data) -> [PeripheralDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sections = root["SPBluetoothDataType"] as? [[String: Any]] else { return nil }
        var devices: [PeripheralDevice] = []
        for section in sections {
            devices += entries(section["device_connected"], connected: true)
            devices += entries(section["device_not_connected"], connected: false)
        }
        // A device can be listed twice across controllers; the connected sighting is the one that matters.
        var byID: [String: PeripheralDevice] = [:]
        for device in devices {
            if let existing = byID[device.id], existing.connected, !device.connected { continue }
            byID[device.id] = device
        }
        return byID.values.sorted { ($0.connected ? 0 : 1, $0.name.lowercased()) < ($1.connected ? 0 : 1, $1.name.lowercased()) }
    }

    private static func entries(_ value: Any?, connected: Bool) -> [PeripheralDevice] {
        guard let list = value as? [[String: Any]] else { return [] }
        return list.flatMap { entry -> [PeripheralDevice] in
            entry.compactMap { name, info in
                guard let fields = info as? [String: Any] else { return nil }
                let address = (fields["device_address"] as? String) ?? name
                return PeripheralDevice(kind: .bluetooth, id: address, name: name,
                                        detail: (fields["device_minorType"] as? String) ?? "",
                                        connected: connected,
                                        vendor: Self.vendor(fields["device_vendorID"] as? String))
            }
        }
    }

    /// Vendor IDs come through as `0x004C`. Only the ones worth naming are named; the rest aren't guessed at.
    static func vendor(_ id: String?) -> String {
        guard let id = id?.lowercased() else { return "" }
        switch id {
        case "0x004c", "0x4c": return "Apple"
        case "0x000f", "0xf": return "Broadcom"
        case "0x0006", "0x6": return "Microsoft"
        case "0x0075", "0x75": return "Samsung"
        case "0x00e0", "0xe0": return "Google"
        case "0x0087", "0x87": return "Garmin"
        case "0x0171", "0x171": return "Amazon"
        default: return ""
        }
    }
}
