import Foundation
import AVFoundation
import Combine

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

    // Suppresses `apply*` work while `loadAVFState` is populating @Published
    // values. SwiftUI `onChange` handlers fire asynchronously after the values
    // propagate, so without this gate the load can trigger a flurry of
    // `lockForConfiguration` calls for state we just read from the device.
    private var isLoadingAVFState = false

    func start() {
        guard controller == nil, startTask == nil else { return }
        refreshDeviceList()
        guard let device = chooseDevice() else {
            errorMessage = UVCError.deviceNotFound.localizedDescription
            return
        }
        selectedDeviceID = device.uniqueID
        launch(device: device)
    }

    func stop() {
        // Flush any state changes before tearing down. `saveSnapshot` is a
        // no-op while `cameraInUse` is true so we never overwrite the saved
        // values with state we never applied.
        saveSnapshot()
        startTask?.cancel()
        startTask = nil
        controller?.closeSession()
        controller = nil
        session = nil
        isReady = false
        cameraInUse = false
    }

    /// Switch to the camera with the given uniqueID. Tears down any in-flight
    /// or open session and re-runs the setup pipeline for the new device.
    func selectDevice(id: String) {
        guard id != selectedDeviceID else { return }
        stop()
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
                let wasBusy = try await cam.openSession(applying: snapshot)
                if Task.isCancelled {
                    cam.closeSession()
                    return
                }
                controller = cam
                session = cam.avf.session
                if wasBusy {
                    cameraInUse = true
                    // Skip AVF state load — populating @Published values would
                    // trigger SwiftUI onChange handlers that call lockForConfiguration,
                    // which fails when another app holds the camera. Skip UVC
                    // restore too — writes would succeed via EP0 but would
                    // override whatever settings the holding app expects.
                    loadUVCState()
                    isReady = true
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
            supportedFPS = formats[index].fps
            let live = Int(cam.avf.currentFPS.rounded())
            fps = supportedFPS.contains(live) ? live : (supportedFPS.first ?? 30)
            if !supportedFPS.contains(live), let f = supportedFPS.first {
                try? cam.avf.setFPS(Double(f))
            }
            saveSnapshot()
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
            saveSnapshot()
        } catch UVCError.deviceInUse { markCameraInUse() }
        catch { errorMessage = error.localizedDescription }
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
