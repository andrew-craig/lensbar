import Foundation
import AVFoundation
import os

private let log = Logger(subsystem: "com.lensbar", category: "camera")

/// Unified entry point combining AVFoundation (focus/exposure/format/fps)
/// and the IOKit UVC path (brightness/contrast/saturation/etc.).
///
/// IOKit UVC failure is non-fatal — the controller is still usable for
/// AVFoundation operations, and `uvc` will be nil. This is the expected
/// outcome for virtual cameras (OBS, Continuity) and for devices that
/// don't expose a UVC VideoControl interface.
@MainActor
final class CameraController {

    let avf: AVFoundationController
    private(set) var uvc: IOKitUVCController?
    let device: AVCaptureDevice

    init(device: AVCaptureDevice) {
        self.device = device
        self.avf = AVFoundationController(device: device)
    }

    /// Open the capture session and, in parallel, read the UVC topology and
    /// probe per-control support off the main thread. The probe is ~20 USB
    /// control transfers and can take 100–200ms; doing it off-main keeps the
    /// menu-bar UI from hitching during camera switch.
    ///
    /// `snapshot` is replayed before `startRunning()` on the AVF side, so the
    /// camera comes up with the user's last-known format/FPS rather than the
    /// firmware default. Returns whether the device was held by another app at
    /// open time; when true, no settings (AVF or UVC) are restored so we don't
    /// fight whatever app currently owns the camera.
    func openSession(applying snapshot: DeviceSnapshot?) async throws -> Bool {
        let locationID = Self.locationID(for: device)
        let deviceName = device.localizedName
        log.info("openSession device=\(deviceName, privacy: .public) uniqueID=\(self.device.uniqueID, privacy: .public) parsedLocationID=\(locationID.map { String(format: "0x%08X", $0) } ?? "nil", privacy: .public)")

        async let avfOpen: Bool = avf.openSession(applying: snapshot)
        async let uvcSetup: IOKitUVCController? = Self.connectUVC(
            locationID: locationID,
            deviceName: deviceName
        )

        let wasBusy = try await avfOpen
        self.uvc = await uvcSetup
        log.info("openSession finished device=\(deviceName, privacy: .public) uvc=\(self.uvc == nil ? "nil" : "available", privacy: .public) wasBusy=\(wasBusy, privacy: .public)")
        return wasBusy
    }

    func closeSession() { avf.closeSession() }

    private nonisolated static func connectUVC(
        locationID: UInt32?,
        deviceName: String
    ) async -> IOKitUVCController? {
        guard let locationID else {
            log.info("connectUVC skipped device=\(deviceName, privacy: .public) reason=no parseable location ID")
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            do {
                let topology = try IOKitUVCController.readTopology(locationID: locationID)
                log.info("connectUVC topology device=\(deviceName, privacy: .public) vcInterface=\(topology.vcInterface) cameraTerminal=\(topology.cameraTerminal.map { String($0) } ?? "nil", privacy: .public) processingUnit=\(topology.processingUnit.map { String($0) } ?? "nil", privacy: .public)")
                return try IOKitUVCController(locationID: locationID, topology: topology)
            } catch {
                log.error("connectUVC failed device=\(deviceName, privacy: .public) error=\(error.localizedDescription, privacy: .public)")
                return nil
            }
        }.value
    }

    /// Extract the IOKit USB location ID from an AVCaptureDevice's `uniqueID`.
    /// For USB cameras on macOS, `uniqueID` encodes
    /// `0x[locationID(8 hex)][idVendor(4 hex)][idProduct(4 hex)]` — 16 hex digits
    /// total — but Apple strips leading zeros from the full value, so the visible
    /// string can be shorter when the location ID has high zero bytes (e.g. an
    /// Opal C1 at locationID `0x00200000` appears as `0x20000003e7f63d`, not
    /// `0x0020000003e7f63d`). The trailing 8 digits are always VID+PID; anything
    /// before that is the location ID. Returns nil for devices without a
    /// parseable location ID — virtual cameras, Continuity Camera, the iOS simulator.
    static func locationID(for device: AVCaptureDevice) -> UInt32? {
        locationID(fromUniqueID: device.uniqueID)
    }

    static func locationID(fromUniqueID uniqueID: String) -> UInt32? {
        var id = uniqueID
        if id.hasPrefix("0x") || id.hasPrefix("0X") { id.removeFirst(2) }
        let hex = String(id.prefix(while: \.isHexDigit))
        guard !hex.isEmpty else { return nil }
        // > 8 digits means we have a VID/PID suffix; drop those 8 trailing nibbles
        // and what's left is the (possibly zero-padded) location ID. ≤ 8 means
        // the suffix has been entirely stripped or was never present — treat the
        // whole run as the location ID.
        let locHex = hex.count > 8 ? String(hex.dropLast(8)) : hex
        return UInt32(locHex, radix: 16)
    }
}
