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
    let uvc: IOKitUVCController?

    init(device: AVCaptureDevice) {
        avf = AVFoundationController(device: device)

        if let locationID = Self.locationID(for: device) {
            do {
                let topology = try IOKitUVCController.readTopology(locationID: locationID)
                uvc = try IOKitUVCController(locationID: locationID, topology: topology)
            } catch {
                uvc = nil
                fputs("Info: IOKit UVC unavailable for \(device.localizedName) " +
                      "(\(error.localizedDescription)) — only AVFoundation controls available\n", stderr)
            }
        } else {
            uvc = nil
        }
    }

    func openSession() async throws { try await avf.openSession() }
    func closeSession() { avf.closeSession() }

    /// Extract the IOKit USB location ID from an AVCaptureDevice's `uniqueID`.
    /// On macOS this is typically an 8-hex-digit value, sometimes prefixed with
    /// "0x" and sometimes followed by additional identifiers (e.g. a serial).
    /// Returns nil for devices without a parseable location ID — virtual cameras,
    /// Continuity Camera, the iOS simulator.
    static func locationID(for device: AVCaptureDevice) -> UInt32? {
        var id = device.uniqueID
        // Strip leading "0x" if present, then take the longest leading run of hex digits.
        if id.hasPrefix("0x") || id.hasPrefix("0X") { id.removeFirst(2) }
        let hex = id.prefix(while: \.isHexDigit)
        guard !hex.isEmpty else { return nil }
        return UInt32(hex, radix: 16)
    }
}
