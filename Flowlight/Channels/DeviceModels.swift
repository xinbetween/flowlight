import Foundation

/// Immediate opt-out state shared by the peripheral monitors. Their serial queues may be blocked inside
/// `system_profiler`, so stop/start intent cannot itself wait on those queues. A new request terminates the exact
/// subprocess in flight and every sample revalidates its generation after each potentially blocking read.
final class PeripheralMonitorLifecycle: @unchecked Sendable {
    private let lock = NSLock()
    private var requestedGeneration: UInt64?
    private var activeProcess: Process?

    func requestStart(generation: UInt64) {
        updateRequest(generation)
    }

    func requestStop() {
        updateRequest(nil)
    }

    func isCurrent(_ generation: UInt64) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return requestedGeneration == generation
    }

    func runSystemProfiler(arguments: [String], generation: UInt64) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        lock.lock()
        guard requestedGeneration == generation else {
            lock.unlock()
            return nil
        }
        activeProcess = process
        do {
            // Holding the lock closes the launch/stop gap: once requestStop can observe this process, it is running.
            try process.run()
        } catch {
            activeProcess = nil
            lock.unlock()
            return nil
        }
        lock.unlock()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        lock.lock()
        if activeProcess === process { activeProcess = nil }
        let accepted = requestedGeneration == generation
        lock.unlock()
        return accepted && process.terminationStatus == 0 ? data : nil
    }

    private func updateRequest(_ generation: UInt64?) {
        lock.lock()
        requestedGeneration = generation
        let process = activeProcess
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }
}

/// A device attached to this Mac by something other than the network: a Bluetooth peripheral, a USB device, a
/// volume that appeared.
///
/// Flowlight counts bytes for network traffic because macOS accounts for them per socket. It cannot do the same
/// here, and says so rather than implying a number it doesn't have: for these channels the honest scope is what is
/// connected, which apps are built to use it, and when that changed.
struct PeripheralDevice: Identifiable, Equatable, Sendable, Codable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case bluetooth, usb, volume, camera

        var title: String {
            switch self {
            case .bluetooth: return L("Bluetooth")
            case .usb: return "USB"
            case .volume: return L("External storage")
            case .camera: return L("Camera")
            }
        }

        var icon: String {
            switch self {
            case .bluetooth: return "dot.radiowaves.right"
            case .usb: return "cable.connector"
            case .volume: return "externaldrive"
            case .camera: return "video"
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
        case appeared, connected, disconnected, removed, started, stopped

        var title: String {
            switch self {
            case .appeared: return L("Paired")
            case .connected: return L("Connected")
            case .disconnected: return L("Disconnected")
            case .removed: return L("Unpaired")
            case .started: return L("Started")
            case .stopped: return L("Stopped")
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
struct CameraDevice: Identifiable, Equatable, Sendable {
    enum State: String, Sendable {
        case active, inactive, unknown
    }

    var id: String
    var name: String
    var manufacturer: String
    var state: State
}

/// A camera arriving is a baseline, not evidence that it just started. Only a confirmed transition between the two
/// known states becomes history; a failed property read must never be presented as "off".
enum CameraDiff {
    static func events(from old: [CameraDevice], to new: [CameraDevice], at now: Date = Date(),
                       firstSighting: Bool = false) -> [DeviceEvent] {
        guard !firstSighting else { return [] }
        let before = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return new.compactMap { camera in
            guard let was = before[camera.id], was.state != camera.state,
                  was.state != .unknown, camera.state != .unknown else { return nil }
            return DeviceEvent(
                at: now,
                kind: .camera,
                deviceID: camera.id,
                name: camera.name,
                detail: camera.manufacturer,
                change: camera.state == .active ? .started : .stopped
            )
        }
        .sorted { $0.name < $1.name }
    }
}

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
