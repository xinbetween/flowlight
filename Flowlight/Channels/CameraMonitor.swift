import CoreMediaIO
import Foundation

protocol CameraMonitoring: AnyObject {
    var onDevices: ([CameraDevice], UInt64) -> Void { get set }
    var onEvents: ([DeviceEvent], UInt64) -> Void { get set }
    func start(generation: UInt64)
    func stop()
    func refresh()
}

/// Whether each camera is active anywhere on this Mac.
///
/// CoreMediaIO exposes only device-level running state. It does not name the process using a camera, and Flowlight
/// does not open a capture session or read a frame to find out. Missing properties and failed reads stay `unknown`
/// rather than being turned into a reassuring but false "inactive".
final class CameraMonitor: CameraMonitoring, @unchecked Sendable {
    var onDevices: ([CameraDevice], UInt64) -> Void = { _, _ in }
    var onEvents: ([DeviceEvent], UInt64) -> Void = { _, _ in }

    private struct Registration {
        var object: CMIOObjectID
        var address: CMIOObjectPropertyAddress
        var listener: CMIOObjectPropertyListenerBlock
    }

    private let queue = DispatchQueue(label: "flowlight.camera", qos: .utility)
    private var registrations: [Registration] = []
    private var fallbackTimer: DispatchSourceTimer?
    private var known: [CameraDevice] = []
    private var sawAnything = false
    private var running = false
    private var generation: UInt64 = 0

    func start(generation: UInt64) {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.generation = generation
            self.running = true
            self.rebuildDeviceListenersAndSample()
        }
    }

    func stop() {
        queue.async { [weak self] in self?.stopOnQueue() }
    }

    func refresh() {
        queue.async { [weak self] in self?.rebuildDeviceListenersAndSample() }
    }

    private func stopOnQueue() {
        guard running || !registrations.isEmpty else { return }
        generation &+= 1
        running = false
        for var registration in registrations {
            _ = CMIOObjectRemovePropertyListenerBlock(
                registration.object,
                &registration.address,
                queue,
                registration.listener
            )
        }
        registrations.removeAll()
        fallbackTimer?.cancel()
        fallbackTimer = nil
        known = []
        sawAnything = false
    }

    private func installDeviceListListener() {
        var address = Self.address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildDeviceListenersAndSample()
        }
        guard CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            queue,
            listener
        ) == noErr else { return }
        registrations.append(Registration(
            object: CMIOObjectID(kCMIOObjectSystemObject),
            address: address,
            listener: listener
        ))
    }

    private func rebuildDeviceListenersAndSample() {
        guard running else { return }
        if !registrations.contains(where: { $0.object == CMIOObjectID(kCMIOObjectSystemObject) }) {
            installDeviceListListener()
        }
        guard let devices = Self.deviceIDs() else { return }
        let cameras = devices.filter(Self.hasInputStream)
        let systemListener = registrations.first { $0.object == CMIOObjectID(kCMIOObjectSystemObject) }
        var needsFallback = systemListener == nil
        for var registration in registrations where registration.object != CMIOObjectID(kCMIOObjectSystemObject) {
            _ = CMIOObjectRemovePropertyListenerBlock(
                registration.object,
                &registration.address,
                queue,
                registration.listener
            )
        }
        registrations = systemListener.map { [$0] } ?? []

        for device in cameras {
            var address = Self.address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
            let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.sample() }
            guard CMIOObjectHasProperty(device, &address),
                  CMIOObjectAddPropertyListenerBlock(device, &address, queue, listener) == noErr else {
                needsFallback = true
                continue
            }
            registrations.append(Registration(object: device, address: address, listener: listener))
        }
        if needsFallback { installFallbackTimer() }
        else {
            fallbackTimer?.cancel()
            fallbackTimer = nil
        }
        sample(deviceIDs: cameras)
    }

    private func sample(deviceIDs: [CMIOObjectID]? = nil) {
        guard running else { return }
        let IDs: [CMIOObjectID]
        if let deviceIDs {
            IDs = deviceIDs
        } else {
            guard let devices = Self.deviceIDs() else { return }
            IDs = devices.filter(Self.hasInputStream)
        }
        let cameras = IDs.map(Self.camera).sorted {
            ($0.state == .active ? 0 : 1, $0.name.lowercased())
                < ($1.state == .active ? 0 : 1, $1.name.lowercased())
        }
        let events = CameraDiff.events(from: known, to: cameras, firstSighting: !sawAnything)
        known = cameras
        sawAnything = true
        let currentGeneration = generation
        onDevices(cameras, currentGeneration)
        if !events.isEmpty { onEvents(events, currentGeneration) }
    }

    private func installFallbackTimer() {
        guard fallbackTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in self?.rebuildDeviceListenersAndSample() }
        timer.resume()
        fallbackTimer = timer
    }

    private static func address(_ selector: CMIOObjectPropertySelector) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: selector,
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    private static func deviceIDs() -> [CMIOObjectID]? {
        var address = address(CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size
        ) == noErr else { return nil }
        guard size > 0 else { return [] }
        var used: UInt32 = 0
        var devices = [CMIOObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<CMIOObjectID>.size
        )
        guard !devices.isEmpty else { return nil }
        guard devices.withUnsafeMutableBytes({ bytes in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                0,
                nil,
                size,
                &used,
                bytes.baseAddress!
            )
        }) == noErr,
              used <= size,
              used % UInt32(MemoryLayout<CMIOObjectID>.size) == 0 else { return nil }
        return Array(devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }

    private static func hasInputStream(_ device: CMIOObjectID) -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyStreams),
            mScope: CMIOObjectPropertyScope(kCMIODevicePropertyScopeInput),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var size: UInt32 = 0
        return CMIOObjectHasProperty(device, &address)
            && CMIOObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr
            && size >= UInt32(MemoryLayout<CMIOStreamID>.size)
    }

    private static func camera(_ device: CMIOObjectID) -> CameraDevice {
        let uid = string(device, CMIOObjectPropertySelector(kCMIODevicePropertyDeviceUID))
        let name = string(device, CMIOObjectPropertySelector(kCMIOObjectPropertyName))
        let manufacturer = string(device, CMIOObjectPropertySelector(kCMIOObjectPropertyManufacturer))
        return CameraDevice(
            id: uid ?? "cmio:\(device)",
            name: name ?? L("Unknown camera"),
            manufacturer: manufacturer ?? "",
            state: runningState(device)
        )
    }

    private static func runningState(_ device: CMIOObjectID) -> CameraDevice.State {
        var address = address(CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere))
        guard CMIOObjectHasProperty(device, &address) else { return .unknown }
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(
                device,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UInt32>.size),
                &used,
                $0
            )
        }
        guard status == noErr, used == MemoryLayout<UInt32>.size else { return .unknown }
        return value == 0 ? .inactive : .active
    }

    private static func string(_ object: CMIOObjectID, _ selector: CMIOObjectPropertySelector) -> String? {
        var address = address(selector)
        guard CMIOObjectHasProperty(object, &address) else { return nil }
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &value) {
            CMIOObjectGetPropertyData(
                object,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<Unmanaged<CFString>?>.size),
                &used,
                $0
            )
        }
        guard status == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}
