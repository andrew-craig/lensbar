@preconcurrency import AVFoundation
import CoreMedia

/// AVFoundation-based camera controls. Works with any AVCaptureDevice;
/// device-specific controls (manual exposure, raw UVC properties) are
/// handled separately by the IOKit/UVC path.
///
/// A capture session must be started before querying live values —
/// openSession() handles this.
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

    /// Enumerate every external camera the system advertises plus the built-in
    /// wide-angle one. The picker UI lets the user choose which to control.
    nonisolated static func enumerateCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.externalUnknown, .builtInWideAngleCamera],
            mediaType: .video,
            position: .unspecified
        ).devices
    }

    // MARK: - Session lifecycle

    /// Open a capture session, optionally pre-applying a persisted snapshot
    /// before `startRunning()` so the camera comes up in its restored
    /// configuration without a default→user transition.
    ///
    /// Returns `wasBusy` — true if another app held the device at probe time.
    /// When busy, no writes are issued (neither AVF lock nor UVC) so we don't
    /// fight whatever app currently owns the camera. The caller skips state
    /// restoration in that case.
    func openSession(applying snapshot: DeviceSnapshot?) async throws -> Bool {
        let sess = AVCaptureSession()
        do {
            let input = try AVCaptureDeviceInput(device: device)
            sess.addInput(input)
        } catch {
            throw UVCError.sessionFailed(error.localizedDescription)
        }

        let busy = isDeviceBusy()

        // Apply persisted format between addInput and startRunning so the
        // camera comes up at the restored resolution — no visible default→user
        // transition. On macOS, explicit `activeFormat` writes inside
        // `lockForConfiguration` are honored even with the default session
        // preset, so no preset change is needed.
        if !busy, let snapshot {
            sess.beginConfiguration()
            applySnapshotPreStart(snapshot, session: sess)
            sess.commitConfiguration()
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

        // Re-apply fps/focus/exposure now that the session is running. These
        // need to go through `lockForConfiguration` on a *running* session to
        // force AVF to renegotiate with the UVC camera; pre-start writes to
        // `activeVideoMinFrameDuration` in particular update the property but
        // don't survive the VS_PROBE/VS_COMMIT negotiation at startRunning, so
        // the camera ends up streaming at the format's default frame rate even
        // though the device reports the saved value back.
        if !busy, let snapshot {
            applySnapshotPostStart(snapshot)
        }
        return busy
    }

    /// Restore the saved format on the device before `startRunning` so the
    /// preview comes up at the right resolution without a default→user flip.
    /// FPS and focus/exposure modes are deliberately deferred to
    /// `applySnapshotPostStart` — pre-start writes to those don't survive
    /// AVF's UVC negotiation at `startRunning`.
    private func applySnapshotPreStart(_ snapshot: DeviceSnapshot, session: AVCaptureSession) {
        guard let w = snapshot.formatWidth,
              let h = snapshot.formatHeight,
              let pf = snapshot.formatPixelFormat,
              let match = Self.matchFormat(in: device.formats, width: w, height: h, pixelFormat: pf) else {
            return
        }
        do {
            try device.lockForConfiguration()
        } catch {
            return
        }
        defer { device.unlockForConfiguration() }
        device.activeFormat = match
    }

    /// Re-apply snapshot values that require a running session. Each write is
    /// best-effort: an unsupported mode or out-of-range fps is skipped rather
    /// than thrown, so partial restoration still works.
    private func applySnapshotPostStart(_ snapshot: DeviceSnapshot) {
        if let fps = snapshot.fps {
            try? setFPS(Double(fps))
        }
        if let focusAuto = snapshot.focusAuto {
            try? focusAuto ? setFocusAuto() : setFocusLocked()
        }
        if let exposureAuto = snapshot.exposureAuto {
            try? exposureAuto ? setExposureAuto() : setExposureLocked()
        }
    }

    static func matchFormat(in formats: [AVCaptureDevice.Format],
                            width: Int32,
                            height: Int32,
                            pixelFormat: UInt32) -> AVCaptureDevice.Format? {
        formats.first { fmt in
            let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
            let subtype = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
            return dims.width == width && dims.height == height && subtype == pixelFormat
        }
    }

    /// Identity of the device's current active format, in a form that survives
    /// persistence and roundtrips through `matchFormat`.
    func activeFormatIdentity() -> (width: Int32, height: Int32, pixelFormat: UInt32) {
        let fmt = device.activeFormat
        let dims = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
        let subtype = CMFormatDescriptionGetMediaSubType(fmt.formatDescription)
        return (dims.width, dims.height, subtype)
    }

    /// Probes whether another app currently holds the camera.
    /// `lockForConfiguration` fails with `AVErrorDeviceInUseByAnotherApplication`
    /// when the device is in use elsewhere. Cheap and side-effect-free
    /// when it succeeds (immediate unlock). Result is point-in-time only — the
    /// device may become contended later (e.g. a vendor DAL plugin acquires the
    /// lock after `startRunning`), so callers must still handle in-use errors
    /// from subsequent `configure` calls.
    func isDeviceBusy() -> Bool {
        do {
            try device.lockForConfiguration()
            device.unlockForConfiguration()
            return false
        } catch let error as AVError where error.code == .deviceInUseByAnotherApplication {
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
        } catch let error as AVError where error.code == .deviceInUseByAnotherApplication {
            throw UVCError.deviceInUse
        } catch {
            throw UVCError.sessionFailed("lockForConfiguration failed: \(error)")
        }
    }
}
