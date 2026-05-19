import Foundation
import AVFoundation

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

        async let avfOpen: Bool = avf.openSession(applying: snapshot)
        async let uvcSetup: IOKitUVCController? = Self.connectUVC(
            locationID: locationID,
            deviceName: deviceName
        )

        let wasBusy = try await avfOpen
        self.uvc = await uvcSetup
        return wasBusy
    }

    func closeSession() { avf.closeSession() }

    private nonisolated static func connectUVC(
        locationID: UInt32?,
        deviceName: String
    ) async -> IOKitUVCController? {
        guard let locationID else { return nil }
        return await Task.detached(priority: .userInitiated) {
            do {
                let topology = try IOKitUVCController.readTopology(locationID: locationID)
                return try IOKitUVCController(locationID: locationID, topology: topology)
            } catch {
                fputs("Info: IOKit UVC unavailable for \(deviceName) " +
                      "(\(error.localizedDescription)) — only AVFoundation controls available\n", stderr)
                return nil
            }
        }.value
    }

    /// Extract the IOKit USB location ID from an AVCaptureDevice's `uniqueID`.
    /// On macOS, `uniqueID` for a USB camera typically looks like the 8-hex-digit
    /// location ID concatenated with an additional vendor/serial suffix (e.g.
    /// `"0x14200000046d082d"`). Take only the first 8 hex digits; the rest is
    /// not part of the location ID and would overflow UInt32.
    /// Returns nil for devices without a parseable location ID — virtual cameras,
    /// Continuity Camera, the iOS simulator.
    static func locationID(for device: AVCaptureDevice) -> UInt32? {
        locationID(fromUniqueID: device.uniqueID)
    }

    static func locationID(fromUniqueID uniqueID: String) -> UInt32? {
        var id = uniqueID
        if id.hasPrefix("0x") || id.hasPrefix("0X") { id.removeFirst(2) }
        let hex = id.prefix(while: \.isHexDigit).prefix(8)
        guard !hex.isEmpty else { return nil }
        return UInt32(hex, radix: 16)
    }
}
