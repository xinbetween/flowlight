import AppKit
import Foundation

/// What is attached over USB, and which volumes have appeared.
///
/// The same honesty applies as to Bluetooth: macOS accounts for no throughput per app on these channels, so this
/// reports arrivals, departures and what a thing is — never how much went through it.
///
/// The two halves work differently on purpose. USB devices come from `system_profiler SPUSBDataType`, which has to
/// be polled; volumes come from `NSWorkspace`, which says the moment one is mounted or ejected. A drive appearing
/// is the event people actually care about, so it is the one that arrives immediately rather than up to half a
/// minute late.
final class USBMonitor: @unchecked Sendable {
    var onDevices: ([PeripheralDevice]) -> Void = { _ in }
    var onEvents: ([DeviceEvent]) -> Void = { _ in }

    private let queue = DispatchQueue(label: "flowlight.usb", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var known: [PeripheralDevice] = []
    private var sawAnything = false
    private var observers: [NSObjectProtocol] = []

    var interval: TimeInterval = 30
    /// Overridable for tests.
    var read: () -> Data? = { USBMonitor.runSystemProfiler() }
    var readVolumes: () -> [PeripheralDevice] = { USBMonitor.mountedVolumes() }

    func start() {
        stop()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval, leeway: .seconds(5))
        timer.setEventHandler { [weak self] in self?.sample() }
        timer.resume()
        self.timer = timer
        // A drive appearing is the event worth knowing about at once, and NSWorkspace says so immediately.
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.queue.async { self?.sample() }
            })
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
    }

    func refresh() { queue.async { [weak self] in self?.sample() } }

    private func sample() {
        var devices = readVolumes()
        if let data = read(), let usb = Self.parse(data) { devices += usb }
        devices.sort { ($0.kind.rawValue, $0.name.lowercased()) < ($1.kind.rawValue, $1.name.lowercased()) }
        let events = DeviceDiff.events(from: known, to: devices, firstSighting: !sawAnything)
        known = devices
        sawAnything = true
        onDevices(devices)
        if !events.isEmpty { onEvents(events) }
    }

    private static func runSystemProfiler() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPUSBDataType", "-json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 ? data : nil
    }

    // MARK: USB

    /// `system_profiler SPUSBDataType -json`, flattened.
    ///
    /// The output is a tree: buses at the top, then hubs, then whatever is plugged into them. Buses and the
    /// built-in hubs are not devices anyone attached, so they are walked through rather than listed — otherwise
    /// every Mac would show a handful of controllers it has always had.
    static func parse(_ data: Data) -> [PeripheralDevice]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let buses = root["SPUSBDataType"] as? [[String: Any]] else { return nil }
        var found: [PeripheralDevice] = []
        for bus in buses { walk(bus, into: &found) }
        var byID: [String: PeripheralDevice] = [:]
        for device in found where byID[device.id] == nil { byID[device.id] = device }
        return byID.values.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func walk(_ node: [String: Any], into found: inout [PeripheralDevice]) {
        let isBus = node["host_controller"] != nil
        if !isBus, let device = device(from: node) { found.append(device) }
        for child in node["_items"] as? [[String: Any]] ?? [] { walk(child, into: &found) }
    }

    private static func device(from node: [String: Any]) -> PeripheralDevice? {
        guard let name = node["_name"] as? String, !name.isEmpty else { return nil }
        // A serial number is the only stable identity; without one, the port it sits in has to do.
        let serial = (node["serial_num"] as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        let location = (node["location_id"] as? String) ?? ""
        let id = !serial.isEmpty ? "usb:\(serial)" : "usb:\(location)/\(name)"
        let media = node["Media"] as? [[String: Any]] ?? []
        let capacity = media.compactMap { $0["size_in_bytes"] as? Int64 }.reduce(0, +)
        return PeripheralDevice(kind: .usb, id: id, name: name,
                                detail: media.isEmpty ? (node["device_speed"] as? String).map(speed) ?? "" : "Storage",
                                connected: true, vendor: vendor(node["manufacturer"] as? String ?? node["vendor_id"] as? String),
                                capacity: capacity)
    }

    /// `high_speed` → `USB 2.0`. Speeds people recognise, and nothing invented for the ones they don't.
    static func speed(_ raw: String) -> String {
        switch raw {
        case "low_speed": return "USB 1.1"
        case "full_speed": return "USB 1.1"
        case "high_speed": return "USB 2.0"
        case "super_speed": return "USB 3.0"
        case "super_speed_plus": return "USB 3.1"
        default: return ""
        }
    }

    /// `0x05ac  (Apple Inc.)` → `Apple Inc.`; a plain manufacturer string is kept as it is.
    static func vendor(_ raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return "" }
        guard let open = raw.firstIndex(of: "("), let close = raw.lastIndex(of: ")"), open < close else {
            return raw.hasPrefix("0x") ? "" : raw
        }
        return String(raw[raw.index(after: open)..<close]).trimmingCharacters(in: .whitespaces)
    }

    // MARK: Volumes

    /// One mounted volume, reduced to what the screen shows.
    struct Volume: Equatable, Sendable {
        var name: String
        var path: String
        var removable: Bool
        var internalDisk: Bool
        var capacity: Int64
    }

    /// The volumes worth listing: the ones that were attached, not the disk the Mac boots from.
    ///
    /// A pure function over what the file system reported, so the rule about which volumes count can be tested
    /// without plugging anything in.
    static func external(_ volumes: [Volume]) -> [PeripheralDevice] {
        volumes.filter { !$0.internalDisk || $0.removable }
            .map { volume in
                PeripheralDevice(kind: .volume, id: "volume:\(volume.path)", name: volume.name,
                                 detail: volume.removable ? "Removable" : "External", connected: true,
                                 capacity: volume.capacity)
            }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func mountedVolumes() -> [PeripheralDevice] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsRemovableKey, .volumeIsInternalKey,
                                      .volumeTotalCapacityKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                         options: [.skipHiddenVolumes]) ?? []
        let volumes = urls.compactMap { url -> Volume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return Volume(name: values.volumeName ?? url.lastPathComponent, path: url.path,
                          removable: values.volumeIsRemovable ?? false,
                          internalDisk: values.volumeIsInternal ?? true,
                          capacity: Int64(values.volumeTotalCapacity ?? 0))
        }
        return external(volumes)
    }
}
