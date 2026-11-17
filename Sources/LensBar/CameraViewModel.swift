import Foundation
import AVFoundation
import Combine
import os
import VirtualCameraKit

private let viewModelLog = Logger(subsystem: "com.andrewcraig.LensBar", category: "Camera")

@MainActor
public final class CameraViewModel: ObservableObject {

    public init() {}

    public struct CameraOption: Identifiable, Equatable {
        public let id: String
        public let name: String
    }

    private static let selectedDeviceDefaultsKey = "lensbar.selectedCameraID"

    // Lifecycle
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published var cameraInUse = false

    // Device picker
    @Published var availableDevices: [CameraOption] = []
    @Published var selectedDeviceID: String?

    // AVFoundation
    @Published var session: AVCaptureSession?
    @Published var formats: [AVFoundationController.FormatInfo] = []
    @Published var formatIndex: Int = 0
    @Published var supportedFPS: [Int] = []
    @Published var fps: Int = 30
    @Published var focusAuto: Bool = true
    @Published var exposureAuto: Bool = true
    @Published var focusAutoSupported: Bool = false
    @Published var exposureAutoSupported: Bool = false

    /// Frame rate measured from real frame timestamps (`RateMonitor`), or nil
    /// when the session isn't delivering frames. Display only — a mismatch with
    /// `fps` means something reset the device; LensBar doesn't correct it.
    @Published var actualFPS: Double?

    /// Number of apps streaming LensBar Camera, as reported by the extension.
    @Published var virtualCameraClients: Int = 0
    /// Whether the LensBar Camera device is visible (extension installed,
    /// approved and running).
    @Published var virtualCameraAvailable = false

    // IOKit UVC — Processing Unit
    @Published var puRanges: [PUControl: ClosedRange<Double>] = [:]
    @Published var puValues: [PUControl: Double] = [:]
    @Published var wbAuto: Bool = false
    @Published var wbAutoSupported: Bool = false
    @Published var hasUVC: Bool = false

    // IOKit UVC — Camera Terminal
    @Published var zoomRange: ClosedRange<Double> = 0...0
    @Published var zoomValue: Double = 0
    @Published var focusRange: ClosedRange<Double> = 0...0
    @Published var focusPosition: Double = 0
    @Published var exposureRange: ClosedRange<Double> = 0...0
    @Published var exposureTime: Double = 0

    // PU controls we expose as sliders (skip the 1-byte mode bytes)
    static let sliderControls: [PUControl] = [
        .brightness, .contrast, .saturation, .hue, .sharpness, .gamma,
        .whiteBalanceTemperature, .backlightCompensation, .gain
    ]

    private var controller: CameraController?
    private var startTask: Task<Void, Never>?
    private var rateTask: Task<Void, Never>?

    /// Session lifetime policy: the camera runs while any demand source is
    /// active (popover open, virtual-camera clients), not just the popover.
    private lazy var pipeline = CapturePipeline(
        start: { [weak self] in self?.openCamera() },
        stop: { [weak self] in self?.closeCamera() }
    )

    /// LensBar Camera plumbing (PLAN.md §6, Phase 3): client count drives the
    /// `.virtualCamera` demand; frames go to the extension's sink.
    private lazy var virtualCamera = VirtualCameraCoordinator(
        setDemand: { [weak self] demanded in
            if demanded { self?.addDemand(.virtualCamera) } else { self?.removeDemand(.virtualCamera) }
        },
        statusChanged: { [weak self] status in
            self?.virtualCameraAvailable = status.available
            self?.virtualCameraClients = status.clients
        },
        clientsArrived: { [weak self] in self?.reassertSettings(reason: "virtual camera client arrived") }
    )
    /// Delay before reopening the camera after a capture-session runtime error.
    static let runtimeErrorRetryDelay: Duration = .seconds(2)
    private var deviceObservers: [NSObjectProtocol] = []
    private var sessionObserver: NSObjectProtocol?
    private var reopenTask: Task<Void, Never>?
    private var reassertTask: Task<Void, Never>?
    /// Attempts made by `reassertSettings` while another app still holds the
    /// camera (a client switching to LensBar Camera releases the physical
    /// device a moment after it starts the virtual one).
    static let reassertRetryDelays: [Duration] = [.zero, .milliseconds(500), .seconds(1), .seconds(2), .seconds(4)]

    // Suppresses `apply*` work while `loadAVFState` is populating @Published
    // values. SwiftUI `onChange` handlers fire asynchronously after the values
    // propagate, so without this gate the load can trigger a flurry of
    // `lockForConfiguration` calls for state we just read from the device.
    private var isLoadingAVFState = false

    // MARK: - Demand

    /// Register a reason for the capture session to run. The session opens on
    /// the first active demand.
    func addDemand(_ source: CaptureDemand) {
        let wasRunning = pipeline.shouldRun
        pipeline.add(source)
        // Opening the popover on a session the virtual camera kept running:
        // nothing else restores settings another app may have changed. A fresh
        // session applies the snapshot itself.
        if source == .popover, wasRunning {
            reassertSettings(reason: "popover opened")
        }
    }

    /// Withdraw a demand. The session closes once no demand is left.
    func removeDemand(_ source: CaptureDemand) {
        pipeline.remove(source)
    }

    private func openCamera() {
        guard controller == nil, startTask == nil else { return }
        refreshDeviceList()
        guard let device = chooseDevice() else {
            errorMessage = UVCError.deviceNotFound.localizedDescription
            return
        }
        selectedDeviceID = device.uniqueID
        launch(device: device)
    }

    /// - Parameter saving: false when the device has gone away, so values read
    ///   from a disconnected device never overwrite the saved snapshot.
    private func closeCamera(saving: Bool = true) {
        // Flush any state changes before tearing down. `saveSnapshot` is a
        // no-op while `cameraInUse` is true so we never overwrite the saved
        // values with state we never applied.
        if saving { saveSnapshot() }
        reopenTask?.cancel()
        reopenTask = nil
        reassertTask?.cancel()
        reassertTask = nil
        observeSession(nil)
        startTask?.cancel()
        startTask = nil
        controller?.closeSession()
        controller = nil
        session = nil
        isReady = false
        cameraInUse = false
        stopRateUpdates()
        virtualCamera.setSessionOpen(controller != nil)
    }

    /// Switch to the camera with the given uniqueID. Tears down any in-flight
    /// or open session and re-runs the setup pipeline for the new device.
    func selectDevice(id: String) {
        guard id != selectedDeviceID else { return }
        closeCamera()
        UserDefaults.standard.set(id, forKey: Self.selectedDeviceDefaultsKey)
        selectedDeviceID = id
        resetPublishedState()
        guard let device = AVFoundationController.enumerateCameras().first(where: { $0.uniqueID == id }) else {
            errorMessage = UVCError.deviceNotFound.localizedDescription
            return
        }
        launch(device: device)
    }

    private func launch(device: AVCaptureDevice) {
        startTask = Task { @MainActor in
            defer { startTask = nil }
            do {
                let cam = CameraController(device: device)
                let snapshot = DeviceSnapshot.load(forDeviceID: device.uniqueID)
                let wasBusy = try await cam.openSession(
                    applying: snapshot,
                    frameOutput: pipeline.frameTap.makeOutput()
                )
                if Task.isCancelled {
                    cam.closeSession()
                    return
                }
                controller = cam
                session = cam.avf.session
                observeSession(cam.avf.session)
                startRateUpdates()
                virtualCamera.setSessionOpen(controller != nil)
                if wasBusy {
                    cameraInUse = true
                    // Skip AVF state load — populating @Published values would
                    // trigger SwiftUI onChange handlers that call lockForConfiguration,
                    // which fails when another app holds the camera. Skip UVC
                    // restore too — writes would succeed via EP0 but would
                    // override whatever settings the holding app expects.
                    loadUVCState()
                    isReady = true
                    pushVirtualCameraFormat()
                    UserDefaults.standard.set(device.uniqueID, forKey: Self.selectedDeviceDefaultsKey)
                    return
                }
                // AVF format/fps/modes already applied pre-startRunning inside
                // openSession. Replay the UVC half now (USB control transfers,
                // no visible disruption to the stream).
                if let snapshot, let uvc = cam.uvc {
                    replayUVC(snapshot: snapshot, uvc: uvc)
                }
                loadAVFState()
                loadUVCState()
                isReady = true
                pushVirtualCameraFormat()
                UserDefaults.standard.set(device.uniqueID, forKey: Self.selectedDeviceDefaultsKey)
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// Replay persisted UVC values. autoExposureMode is applied before
    /// exposureTimeAbsolute because the UVC spec requires manual AE mode for
    /// exposure-time writes to take effect (see CLAUDE.md).
    private func replayUVC(snapshot: DeviceSnapshot, uvc: IOKitUVCController) {
        for ctrl in Self.sliderControls where uvc.isSupported(ctrl) {
            if let v = snapshot.pu(ctrl) {
                try? uvc.setPU(ctrl, value: Int16(clamping: v))
            }
        }
        if uvc.isSupported(.whiteBalanceTempAuto), let v = snapshot.pu(.whiteBalanceTempAuto) {
            try? uvc.setPU(.whiteBalanceTempAuto, value: Int16(clamping: v))
        }
        if uvc.isSupported(.autoExposureMode), let v = snapshot.ct(.autoExposureMode) {
            try? uvc.setCT(.autoExposureMode, value: v)
        }
        if uvc.isSupported(.exposureTimeAbsolute), let v = snapshot.ct(.exposureTimeAbsolute) {
            try? uvc.setCT(.exposureTimeAbsolute, value: v)
        }
        if uvc.isSupported(.zoomAbsolute), let v = snapshot.ct(.zoomAbsolute) {
            try? uvc.setCT(.zoomAbsolute, value: v)
        }
        if uvc.isSupported(.focusAbsolute), let v = snapshot.ct(.focusAbsolute) {
            try? uvc.setCT(.focusAbsolute, value: v)
        }
    }

    /// Clear published state when switching devices so stale slider ranges,
    /// values, and capability flags don't bleed across cameras. Also resets
    /// AVF toggle/picker state so `onChange` doesn't fire spuriously when the
    /// next camera's loaded state happens to differ from the prior camera's.
    private func resetPublishedState() {
        isLoadingAVFState = true
        defer { isLoadingAVFState = false }
        errorMessage = nil
        formats = []
        formatIndex = 0
        supportedFPS = []
        fps = 30
        focusAuto = true
        exposureAuto = true
        puRanges = [:]
        puValues = [:]
        wbAuto = false
        wbAutoSupported = false
        hasUVC = false
        zoomRange = 0...0
        zoomValue = 0
        focusRange = 0...0
        focusPosition = 0
        exposureRange = 0...0
        exposureTime = 0
        focusAutoSupported = false
        exposureAutoSupported = false
    }

    private func refreshDeviceList() {
        availableDevices = AVFoundationController.enumerateCameras().map {
            CameraOption(id: $0.uniqueID, name: $0.localizedName)
        }
    }

    /// Pick the device to use on launch: the persisted last selection if it's
    /// still plugged in, otherwise the first available camera.
    private func chooseDevice() -> AVCaptureDevice? {
        let devices = AVFoundationController.enumerateCameras()
        let saved = UserDefaults.standard.string(forKey: Self.selectedDeviceDefaultsKey)
        if let saved, let match = devices.first(where: { $0.uniqueID == saved }) {
            return match
        }
        return devices.first
    }

    // MARK: - AVFoundation state

    private func loadAVFState() {
        guard let cam = controller else { return }
        isLoadingAVFState = true
        let info = cam.avf.info()
        formats = info.formats
        formatIndex = info.formats.firstIndex(where: { $0.isActive }) ?? 0
        focusAutoSupported = cam.avf.device.isFocusModeSupported(.continuousAutoFocus)
        exposureAutoSupported = cam.avf.device.isExposureModeSupported(.continuousAutoExposure)
        focusAuto = focusAutoSupported && info.focusMode == .continuousAutoFocus
        exposureAuto = exposureAutoSupported && info.exposureMode == .continuousAutoExposure
        supportedFPS = formats.indices.contains(formatIndex) ? formats[formatIndex].fps : []
        let live = Int(cam.avf.currentFPS.rounded())
        fps = supportedFPS.contains(live) ? live : (supportedFPS.first ?? 30)
        // Defer the flag clear so SwiftUI's `onChange` callbacks (which fire
        // asynchronously after the @Published values propagate) see it as still
        // loading and skip their apply work.
        Task { @MainActor in isLoadingAVFState = false }
    }

    // MARK: - UVC state

    private func loadUVCState() {
        guard let uvc = controller?.uvc else {
            hasUVC = false
            return
        }
        hasUVC = true
        for ctrl in Self.sliderControls where uvc.isSupported(ctrl) {
            if let r = uvc.getPURange(ctrl) {
                puRanges[ctrl] = Double(r.min)...Double(r.max)
                puValues[ctrl] = Double(r.current)
            }
        }
        if uvc.isSupported(.whiteBalanceTempAuto), let auto = uvc.getPU(.whiteBalanceTempAuto) {
            wbAutoSupported = true
            wbAuto = auto != 0
        } else {
            wbAutoSupported = false
            wbAuto = false
        }
        if uvc.isSupported(.zoomAbsolute),
           let cur = uvc.getCT(.zoomAbsolute),
           let lo = uvc.getCT(.zoomAbsolute, request: .getMin),
           let hi = uvc.getCT(.zoomAbsolute, request: .getMax),
           hi > lo {
            zoomRange = Double(lo)...Double(hi)
            zoomValue = Double(cur)
        }
        if uvc.isSupported(.focusAbsolute),
           let cur = uvc.getCT(.focusAbsolute),
           let lo = uvc.getCT(.focusAbsolute, request: .getMin),
           let hi = uvc.getCT(.focusAbsolute, request: .getMax),
           hi > lo {
            focusRange = Double(lo)...Double(hi)
            focusPosition = Double(cur)
        }
        if uvc.isSupported(.exposureTimeAbsolute),
           let cur = uvc.getCT(.exposureTimeAbsolute),
           let lo = uvc.getCT(.exposureTimeAbsolute, request: .getMin),
           let hi = uvc.getCT(.exposureTimeAbsolute, request: .getMax),
           hi > lo {
            exposureRange = Double(lo)...Double(hi)
            exposureTime = Double(cur)
        }
    }

    // MARK: - Setters (AVFoundation)

    func applyFormat(_ index: Int) {
        guard !isLoadingAVFState, let cam = controller, formats.indices.contains(index) else { return }
        do {
            try cam.avf.setFormat(index: index)
            pipeline.rateMonitor.reset()
            supportedFPS = formats[index].fps
            let live = Int(cam.avf.currentFPS.rounded())
            fps = supportedFPS.contains(live) ? live : (supportedFPS.first ?? 30)
            if !supportedFPS.contains(live), let f = supportedFPS.first {
                try? cam.avf.setFPS(Double(f))
            }
            saveSnapshot()
            pushVirtualCameraFormat()
        } catch UVCError.deviceInUse {
            markCameraInUse()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyFPS(_ rate: Int) {
        guard !isLoadingAVFState, let cam = controller else { return }
        do {
            try cam.avf.setFPS(Double(rate))
            pipeline.rateMonitor.reset()
            saveSnapshot()
            pushVirtualCameraFormat()
        } catch UVCError.deviceInUse { markCameraInUse() }
        catch { errorMessage = error.localizedDescription }
    }

    /// Re-assert the current frame rate on the live device. Attaching an
    /// `AVCaptureVideoPreviewLayer` to a running session synchronously resets
    /// the device's frame duration to the active format's default, silently
    /// undoing the FPS restored at launch (the displayed value stays correct
    /// because it was read before the preview attached, so only the real stream
    /// drifts). `CameraPreview` calls this the moment it attaches the session.
    /// Idempotent and safe to call repeatedly.
    func reapplyFrameRate() {
        guard !cameraInUse, let cam = controller else { return }
        try? cam.avf.setFPS(Double(fps))
    }

    // MARK: - Re-asserting settings

    private enum ReassertOutcome { case done, busy }

    /// Put the user's saved settings (format, frame rate, focus/exposure modes,
    /// UVC controls) back on the running camera. Event-triggered only — when a
    /// LensBar Camera client arrives or the popover opens — never on a timer,
    /// so it is not the rejected drift watchdog (PLAN.md §3). Retries briefly
    /// while another app still holds the device, and clears `cameraInUse` once
    /// the device is free. If a session is still opening, waits for it first.
    func reassertSettings(reason: String) {
        reassertTask?.cancel()
        reassertTask = Task { @MainActor [weak self] in
            for delay in Self.reassertRetryDelays {
                if delay > .zero { try? await Task.sleep(for: delay) }
                if let opening = self?.startTask { await opening.value }
                guard !Task.isCancelled, let self else { return }
                guard controller != nil else { return }
                if reassertOnce(reason: reason) == .done { return }
            }
            viewModelLog.info("re-assert gave up: camera still in use (\(reason, privacy: .public))")
        }
    }

    private func reassertOnce(reason: String) -> ReassertOutcome {
        guard let cam = controller, let deviceID = selectedDeviceID else { return .done }
        var snapshot = DeviceSnapshot.load(forDeviceID: deviceID) ?? DeviceSnapshot()
        if snapshot.fps == nil, !cameraInUse { snapshot.fps = fps }
        // Only bounce the frame duration when the measured stream rate shows the
        // camera really is off target, so a re-assert on an already-correct
        // stream doesn't stutter a live call.
        let measured = pipeline.rateMonitor.framesPerSecond()
        let drifted = snapshot.fps.flatMap { target in measured.map { abs($0 - Double(target)) > 1.0 } } ?? false
        do {
            try cam.avf.reassert(snapshot, forceRenegotiation: drifted)
        } catch UVCError.deviceInUse {
            return .busy
        } catch {
            viewModelLog.error("re-assert failed (\(reason, privacy: .public)): \(error.localizedDescription, privacy: .public)")
            return .done
        }
        let measuredText = measured.map { String(format: "%.1f", $0) } ?? "none"
        viewModelLog.info("re-asserted settings (\(reason, privacy: .public)) fps=\(snapshot.fps ?? 0) measured=\(measuredText, privacy: .public) renegotiated=\(drifted) recoveredFromInUse=\(self.cameraInUse)")
        pipeline.rateMonitor.reset()
        if let uvc = cam.uvc { replayUVC(snapshot: snapshot, uvc: uvc) }
        cameraInUse = false
        loadAVFState()
        loadUVCState()
        pushVirtualCameraFormat()
        return .done
    }

    // MARK: - Measured frame rate

    /// Poll the rate monitor twice a second while a session is open. Frames
    /// are recorded on the capture queue; publishing at a fixed cadence keeps
    /// SwiftUI updates off the per-frame path.
    private func startRateUpdates() {
        rateTask?.cancel()
        pipeline.rateMonitor.reset()
        let monitor = pipeline.rateMonitor
        rateTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let measured = monitor.framesPerSecond().map { ($0 * 10).rounded() / 10 }
                if let self, self.actualFPS != measured { self.actualFPS = measured }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    private func stopRateUpdates() {
        rateTask?.cancel()
        rateTask = nil
        actualFPS = nil
    }

    func applyFocusMode() {
        guard !isLoadingAVFState, let cam = controller else { return }
        do {
            if focusAuto { try cam.avf.setFocusAuto() }
            else { try cam.avf.setFocusLocked() }
            saveSnapshot()
        } catch UVCError.deviceInUse {
            markCameraInUse()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyExposureMode() {
        guard !isLoadingAVFState, let cam = controller else { return }
        // AVFoundation auto/locked is reliable; the UVC AE mode write is what
        // actually puts the camera into manual mode so exposureTimeAbsolute
        // writes take effect on this external UVC device.
        do {
            if exposureAuto { try cam.avf.setExposureAuto() }
            else { try cam.avf.setExposureLocked() }
        } catch UVCError.deviceInUse {
            markCameraInUse()
            return
        } catch {
            errorMessage = error.localizedDescription
        }
        if let uvc = cam.uvc, uvc.isSupported(.autoExposureMode) {
            let mode: AEMode = exposureAuto ? .auto : .manual
            report { try uvc.setCT(.autoExposureMode, value: Int(mode.rawValue)) }
        }
        saveSnapshot()
    }

    /// Called when an AVFoundation operation fails because another process now
    /// holds the device. Hides the AVF section instead of surfacing a raw error.
    private func markCameraInUse() {
        cameraInUse = true
        errorMessage = nil
    }

    // MARK: - Setters (UVC)

    func commitPU(_ ctrl: PUControl) {
        guard let uvc = controller?.uvc, let v = puValues[ctrl] else { return }
        report { try uvc.setPU(ctrl, value: Int16(v.rounded())) }
        saveSnapshot()
    }

    func applyWBAuto() {
        // `loadUVCState` writes `wbAuto`, which fires Toggle's onChange — without
        // this guard the load would round-trip a redundant USB write back to the
        // camera. Slider commits don't need the same guard because they fire from
        // `onEditingChanged`, not from programmatic value changes.
        guard !isLoadingAVFState, let uvc = controller?.uvc else { return }
        report { try uvc.setPU(.whiteBalanceTempAuto, value: wbAuto ? 1 : 0) }
        saveSnapshot()
    }

    func commitZoom() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setCT(.zoomAbsolute, value: Int(zoomValue.rounded())) }
        saveSnapshot()
    }

    func commitFocusPosition() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setCT(.focusAbsolute, value: Int(focusPosition.rounded())) }
        saveSnapshot()
    }

    func commitExposureTime() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setCT(.exposureTimeAbsolute, value: Int(exposureTime.rounded())) }
        saveSnapshot()
    }

    private func report(_ work: () throws -> Void) {
        do {
            try work()
            if errorMessage != nil { errorMessage = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Snapshot persistence

    /// Capture current @Published state and persist it for this device. Skipped
    /// while another app holds the camera (so we never overwrite the saved
    /// settings with values we didn't actually apply) and while initial AVF
    /// state is loading (the @Published values aren't trustworthy mid-load).
    private func saveSnapshot() {
        guard !cameraInUse, !isLoadingAVFState else { return }
        guard let cam = controller else { return }
        guard let deviceID = selectedDeviceID else { return }

        var snap = DeviceSnapshot()
        let id = cam.avf.activeFormatIdentity()
        snap.formatWidth = id.width
        snap.formatHeight = id.height
        snap.formatPixelFormat = id.pixelFormat
        snap.fps = fps
        snap.focusAuto = focusAuto
        snap.exposureAuto = exposureAuto

        for (ctrl, v) in puValues {
            snap.setPU(ctrl, Int(v.rounded()))
        }
        if wbAutoSupported {
            snap.setPU(.whiteBalanceTempAuto, wbAuto ? 1 : 0)
        }
        if zoomRange.upperBound > zoomRange.lowerBound {
            snap.setCT(.zoomAbsolute, Int(zoomValue.rounded()))
        }
        if focusRange.upperBound > focusRange.lowerBound {
            snap.setCT(.focusAbsolute, Int(focusPosition.rounded()))
        }
        if exposureRange.upperBound > exposureRange.lowerBound {
            snap.setCT(.exposureTimeAbsolute, Int(exposureTime.rounded()))
        }
        if let uvc = cam.uvc, uvc.isSupported(.autoExposureMode) {
            snap.setCT(.autoExposureMode, Int((exposureAuto ? AEMode.auto : .manual).rawValue))
        }

        snap.save(forDeviceID: deviceID)
    }
}

// MARK: - Virtual camera, unplug / replug

extension CameraViewModel {
    /// Start serving LensBar Camera: watch its client count, feed its sink
    /// while the capture session runs, and recover from camera unplug/replug.
    /// Called once at app launch, so a client that is already streaming when
    /// LensBar (re)launches gets video without the popover being opened.
    public func startVirtualCamera() {
        guard deviceObservers.isEmpty else { return }
        observeDeviceConnections()
        virtualCamera.start(frameTap: pipeline.frameTap)
    }

    /// Push the format LensBar is producing to the extension.
    private func pushVirtualCameraFormat() {
        guard let cam = controller else { return }
        let identity = cam.avf.activeFormatIdentity()
        let live = cam.avf.currentFPS
        virtualCamera.pushFormat(width: identity.width, height: identity.height, fps: live > 0 ? live : Double(fps))
    }

    /// Close the session when the camera in use is unplugged, and reopen when
    /// a camera comes back while something still wants capture. Clients keep
    /// LensBar Camera selected throughout; the extension shows its placeholder
    /// during the gap.
    private func observeDeviceConnections() {
        let center = NotificationCenter.default
        deviceObservers.append(center.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification,
                                                  object: nil, queue: .main) { [weak self] note in
            let uniqueID = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.deviceDisconnected(uniqueID: uniqueID) }
        })
        deviceObservers.append(center.addObserver(forName: AVCaptureDevice.wasConnectedNotification,
                                                  object: nil, queue: .main) { [weak self] note in
            let uniqueID = (note.object as? AVCaptureDevice)?.uniqueID
            MainActor.assumeIsolated { self?.deviceConnected(uniqueID: uniqueID) }
        })
    }

    private func deviceDisconnected(uniqueID: String?) {
        guard let uniqueID, !VirtualCameraIdentity.isOwnDevice(uniqueID: uniqueID) else { return }
        refreshDeviceList()
        guard uniqueID == selectedDeviceID, controller != nil || startTask != nil else { return }
        viewModelLog.info("camera disconnected; waiting for it to return")
        closeCamera(saving: false)
        errorMessage = "Camera disconnected."
    }

    private func deviceConnected(uniqueID: String?) {
        guard let uniqueID, !VirtualCameraIdentity.isOwnDevice(uniqueID: uniqueID) else { return }
        refreshDeviceList()
        guard pipeline.shouldRun, controller == nil, startTask == nil else { return }
        viewModelLog.info("camera connected; reopening capture")
        errorMessage = nil
        openCamera()
    }

    /// Watch the running session for runtime errors (e.g. the camera stalls or
    /// is reset underneath it) and reopen once after a short delay. A
    /// disconnect is left to `deviceDisconnected`.
    private func observeSession(_ session: AVCaptureSession?) {
        if let sessionObserver { NotificationCenter.default.removeObserver(sessionObserver) }
        sessionObserver = nil
        guard let session else { return }
        sessionObserver = NotificationCenter.default.addObserver(forName: AVCaptureSession.runtimeErrorNotification,
                                                                 object: session, queue: .main) { [weak self] note in
            let error = note.userInfo?[AVCaptureSessionErrorKey] as? NSError
            let description = error?.localizedDescription ?? "unknown"
            MainActor.assumeIsolated { self?.sessionRuntimeError(description) }
        }
    }

    private func sessionRuntimeError(_ description: String) {
        guard let cam = controller else { return }
        viewModelLog.error("capture session runtime error: \(description, privacy: .public)")
        guard cam.avf.device.isConnected else { return }
        closeCamera()
        reopenTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.runtimeErrorRetryDelay)
            guard !Task.isCancelled, let self else { return }
            reopenTask = nil
            if pipeline.shouldRun, controller == nil, startTask == nil { openCamera() }
        }
    }
}
