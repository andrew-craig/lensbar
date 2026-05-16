import Foundation
import AVFoundation

/// Unified entry point combining AVFoundation (focus/exposure/format/fps)
/// and the IOKit UVC path (brightness/contrast/saturation/etc.).
///
/// IOKit UVC failure is non-fatal — the controller is still usable for
/// AVFoundation operations, and `uvc` will be nil.
final class CameraController {

    let avf: AVFoundationController
    let uvc: IOKitUVCController?

    init() throws {
        guard let dev = AVFoundationController.findOBSBOT() else {
            throw UVCError.deviceNotFound
        }
        avf = AVFoundationController(device: dev)

        do {
            uvc = try IOKitUVCController()
        } catch {
            uvc = nil
            fputs("Warning: IOKit UVC unavailable (\(error.localizedDescription)) — " +
                  "brightness/contrast/etc. controls will not work\n", stderr)
        }
    }

    func openSession() throws { try avf.openSession() }
    func closeSession() { avf.closeSession() }
}
