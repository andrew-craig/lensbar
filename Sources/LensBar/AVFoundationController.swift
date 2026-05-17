@preconcurrency import AVFoundation
import CoreMedia

/// AVFoundation-based camera controls.
///
/// Confirmed working on OBSBOT Meet SE (see CAMERA_CAPABILITIES.md):
///   - Focus: continuous auto / locked
///   - Exposure: continuous auto / locked
///   - Format / resolution switching
///   - Frame rate control
///
/// A capture session must be started before querying live values (ISO,
/// exposure duration, lens position) — openSession() handles this.
@MainActor
final class AVFoundationController {

    let device: AVCaptureDevice
    private(set) var session: AVCaptureSession?

    // AVCaptureSession.startRunning() is blocking; Apple requires it to run
    // off the main queue. A dedicated serial queue keeps session mutations ordered.
    private let sessionQueue = DispatchQueue(label: "com.lensbar.session")

    init(device: AVCaptureDevice) {
        self.device = device
    }

    nonisolated static func findOBSBOT() -> AVCaptureDevice? {
        let session = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        )
        return session.devices.first { $0.localizedName.contains(OBSBOT.name) }
    }

    // MARK: - Session lifecycle

    func openSession() async throws {
        let sess = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            sess.addInput(input)
        } catch {
            throw UVCError.sessionFailed(error.localizedDescription)
        }
        let queue = sessionQueue
        await withCheckedContinuation { continuation in
            queue.async {
                sess.startRunning()
                continuation.resume()
            }
        }
        if Task.isCancelled {
            queue.async { sess.stopRunning() }
            throw CancellationError()
        }
        self.session = sess
    }

    /// Probes whether another app currently holds the camera.
    /// `lockForConfiguration` fails with `AVErrorDeviceInUseByAnotherApplication`
    /// (-11817) when the device is in use elsewhere. Cheap and side-effect-free
    /// when it succeeds (immediate unlock).
    func isDeviceBusy() -> Bool {
        do {
            try device.lockForConfiguration()
            device.unlockForConfiguration()
            return false
        } catch let error as NSError
            where error.domain == AVFoundationErrorDomain
            && error.code == AVError.deviceInUseByAnotherApplication.rawValue {
            return true
        } catch {
            return false
        }
    }

    var currentFPS: Double {
        let dur = device.activeVideoMinFrameDuration
        guard dur.value > 0 else { return 0 }
        return Double(dur.timescale) / Double(dur.value)
    }

    func closeSession() {
        guard let sess = session else { return }
        session = nil
        sessionQueue.async { sess.stopRunning() }
    }

    // MARK: - Info

    struct FormatInfo {
        let index: Int
        let width: Int32
        let height: Int32
        let fps: [Int]
        let isActive: Bool
    }

    struct CameraInfo {
        let name: String
        let activeWidth: Int32
        let activeHeight: Int32
        let exposureMode: AVCaptureDevice.ExposureMode
        // NOTE: iso, exposureDuration, lensPosition are iOS-only AVFoundation properties
        // and are not accessible on macOS. The Python scripts access them via PyObjC runtime
        // introspection which bypasses compile-time availability checks.
        let focusMode: AVCaptureDevice.FocusMode
        let whiteBalanceMode: AVCaptureDevice.WhiteBalanceMode
        let formats: [FormatInfo]
    }

    func info() -> CameraInfo {
        let activeFmt = device.activeFormat
        let activeDims = CMVideoFormatDescriptionGetDimensions(activeFmt.formatDescription)

        let formats = device.formats.enumerated().map { i, fmt -> FormatInfo in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let fps = Set(fmt.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }).sorted(by: >)
            return FormatInfo(
                index: i,
                width: dims.width,
                height: dims.height,
                fps: fps,
                isActive: fmt == activeFmt
            )
        }

        return CameraInfo(
            name: device.localizedName,
            activeWidth: activeDims.width,
            activeHeight: activeDims.height,
            exposureMode: device.exposureMode,
            focusMode: device.focusMode,
            whiteBalanceMode: device.whiteBalanceMode,
            formats: formats
        )
    }

    // MARK: - Focus

    func setFocusAuto() throws {
        guard device.isFocusModeSupported(.continuousAutoFocus) else {
            throw UVCError.invalidValue("Continuous autofocus not supported")
        }
        try configure { $0.focusMode = .continuousAutoFocus }
    }

    func setFocusLocked() throws {
        try configure { $0.focusMode = .locked }
    }

    // MARK: - Exposure

    func setExposureAuto() throws {
        guard device.isExposureModeSupported(.continuousAutoExposure) else {
            throw UVCError.invalidValue("Continuous auto exposure not supported")
        }
        try configure { $0.exposureMode = .continuousAutoExposure }
    }

    func setExposureLocked() throws {
        try configure { $0.exposureMode = .locked }
    }

    // MARK: - Format

    func setFormat(index: Int) throws {
        let formats = device.formats
        guard index >= 0 && index < formats.count else {
            throw UVCError.invalidValue("Format index \(index) out of range 0–\(formats.count - 1)")
        }
        try configure { $0.activeFormat = formats[index] }
    }

    // MARK: - Frame rate

    func setFPS(_ rate: Double) throws {
        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard let best = ranges.min(by: { abs($0.maxFrameRate - rate) < abs($1.maxFrameRate - rate) }),
              abs(best.maxFrameRate - rate) <= 1.0
        else {
            let avail = ranges.map { String(format: "%.2f", $0.maxFrameRate) }.joined(separator: ", ")
            throw UVCError.invalidValue("FPS \(rate) not supported. Available: \(avail)")
        }
        let dur = best.minFrameDuration
        try configure {
            $0.activeVideoMinFrameDuration = dur
            $0.activeVideoMaxFrameDuration = dur
        }
    }

    // MARK: - Private

    private func configure(_ block: (AVCaptureDevice) -> Void) throws {
        do {
            try device.lockForConfiguration()
            block(device)
            device.unlockForConfiguration()
        } catch {
            throw UVCError.sessionFailed("lockForConfiguration failed: \(error)")
        }
    }
}
