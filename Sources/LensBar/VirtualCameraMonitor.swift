import CoreMediaIO
import Foundation
import os
import VirtualCameraKit

private let monitorLog = Logger(subsystem: "com.andrewcraig.LensBar", category: "VirtualCamera")

/// Tracks LensBar Camera from the app side through the CMIO C API:
///
/// - finds the device by UID, and re-finds it whenever the system device list
///   or the device's stream list changes (the CMIO object ID and stream IDs
///   change on extension restart and on device replacement);
/// - reports the sink endpoint the app should feed;
/// - listens to the `lbcc` client-count property (pushed by the extension in
///   about 40 ms), with a slow poll as a safety net only;
/// - writes LensBar's current format to `lbfm`, again whenever the device
///   object changes, so the extension always knows what to advertise next.
///
/// Nothing here needs camera permission or an entitlement. When the extension
/// isn't installed or approved, the device simply never appears.
@MainActor
final class VirtualCameraMonitor {
    /// Safety-net poll interval (PLAN.md §7: listeners are reliable, poll slowly).
    static let pollInterval: Duration = .seconds(5)

    private(set) var endpoint: VirtualCameraEndpoint?
    private(set) var clientCount = 0

    var onEndpointChange: ((VirtualCameraEndpoint?) -> Void)?
    var onClientCountChange: ((Int) -> Void)?

    private var started = false
    private var listenedDevices: Set<CMIOObjectID> = []
    private var pollTask: Task<Void, Never>?

    /// Latest format LensBar wants advertised, and what was last written to
    /// which device object.
    private var desiredFormat: VirtualCameraFormat?
    private var writtenFormat: (device: CMIOObjectID, format: VirtualCameraFormat)?

    private let countSelector = VirtualCameraProperty.clientCount.selector
    private let formatSelector = VirtualCameraProperty.format.selector

    func start() {
        guard !started else { return }
        started = true
        CMIOHardware.allowExtensionDevices()
        // The device list fills in asynchronously on first use; this listener
        // picks the device up when it arrives.
        CMIOHardware.addListener(object: CMIOHardware.systemObject,
                                 selector: UInt32(kCMIOHardwarePropertyDevices),
                                 queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.refresh(reason: "device list") }
        }
        refresh(reason: "start")
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                self?.refresh(reason: nil)
            }
        }
    }

    /// Tell the extension which format to advertise from its next zero-client
    /// moment (PLAN.md §4.5). Written now if the device is present, otherwise
    /// as soon as it appears.
    func pushFormat(_ format: VirtualCameraFormat) {
        desiredFormat = format
        writeFormatIfNeeded()
    }

    // MARK: Private

    private func refresh(reason: String?) {
        let device = CMIOHardware.device(withUID: VirtualCameraIdentity.deviceUID)
        if let device { listen(to: device) }

        let newEndpoint = device.flatMap { dev in
            CMIOHardware.sinkStream(of: dev).map { VirtualCameraEndpoint(device: dev, sinkStream: $0) }
        }
        if newEndpoint != endpoint {
            endpoint = newEndpoint
            let description = newEndpoint.map { "device \($0.device) sink \($0.sinkStream)" } ?? "none"
            monitorLog.info("endpoint \(description, privacy: .public) (\(reason ?? "poll", privacy: .public))")
            onEndpointChange?(newEndpoint)
        }

        let count = device
            .flatMap { CMIOHardware.string(of: $0, selector: countSelector) }
            .flatMap(ClientCountCodec.decode) ?? 0
        if count != clientCount {
            clientCount = count
            monitorLog.info("clients \(count)")
            onClientCountChange?(count)
        }

        writeFormatIfNeeded()
    }

    /// Add property listeners once per device object. Listeners on objects
    /// that have since gone away are harmless; their callbacks just refresh.
    private func listen(to device: CMIOObjectID) {
        guard listenedDevices.insert(device).inserted else { return }
        for (selector, name) in [(countSelector, "clients"), (UInt32(kCMIODevicePropertyStreams), "streams")] {
            let status = CMIOHardware.addListener(object: device, selector: selector, queue: .main) { [weak self] in
                MainActor.assumeIsolated { self?.refresh(reason: name) }
            }
            if status != noErr {
                monitorLog.error("listener \(name, privacy: .public) on device \(device) failed: \(status)")
            }
        }
    }

    private func writeFormatIfNeeded() {
        guard let desiredFormat, let device = endpoint?.device else { return }
        if let writtenFormat, writtenFormat.device == device, writtenFormat.format == desiredFormat { return }
        let status = CMIOHardware.setString(desiredFormat.encoded, of: device, selector: formatSelector)
        if status == noErr {
            writtenFormat = (device, desiredFormat)
            monitorLog.info("pushed format \(desiredFormat.encoded, privacy: .public) to device \(device)")
        } else {
            monitorLog.error("pushing format \(desiredFormat.encoded, privacy: .public) failed: \(status)")
        }
    }
}
