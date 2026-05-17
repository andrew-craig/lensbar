import Foundation
import AVFoundation
import Combine

@MainActor
public final class CameraViewModel: ObservableObject {

    public init() {}


    // Lifecycle
    @Published var isReady = false
    @Published var errorMessage: String?
    @Published var cameraInUse = false

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

    func start() {
        guard controller == nil, startTask == nil else { return }
        startTask = Task { @MainActor in
            defer { startTask = nil }
            do {
                let cam = try CameraController()
                try await cam.openSession()
                if Task.isCancelled {
                    cam.closeSession()
                    return
                }
                controller = cam
                session = cam.avf.session
                if cam.avf.isDeviceBusy() {
                    cameraInUse = true
                    // Skip AVF state load — populating @Published values would
                    // trigger SwiftUI onChange handlers that call lockForConfiguration,
                    // which fails when another app holds the camera.
                    loadUVCState()
                    isReady = true
                    return
                }
                loadAVFState()
                loadUVCState()
                isReady = true
            } catch is CancellationError {
                return
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        controller?.closeSession()
        controller = nil
        session = nil
        isReady = false
        cameraInUse = false
    }

    // MARK: - AVFoundation state

    private func loadAVFState() {
        guard let cam = controller else { return }
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
    }

    // MARK: - UVC state

    private func loadUVCState() {
        guard let uvc = controller?.uvc else {
            hasUVC = false
            return
        }
        hasUVC = true
        for ctrl in Self.sliderControls {
            if let r = uvc.getPURange(ctrl) {
                puRanges[ctrl] = Double(r.min)...Double(r.max)
                puValues[ctrl] = Double(r.current)
            }
        }
        if let auto = uvc.getPU(.whiteBalanceTempAuto) {
            wbAutoSupported = true
            wbAuto = auto != 0
        } else {
            wbAutoSupported = false
            wbAuto = false
        }
        if let cur = uvc.getCT(.zoomAbsolute),
           let lo = uvc.getCT(.zoomAbsolute, request: .getMin),
           let hi = uvc.getCT(.zoomAbsolute, request: .getMax),
           hi > lo {
            zoomRange = Double(lo)...Double(hi)
            zoomValue = Double(cur)
        }
        if let cur = uvc.getCT(.focusAbsolute),
           let lo = uvc.getCT(.focusAbsolute, request: .getMin),
           let hi = uvc.getCT(.focusAbsolute, request: .getMax),
           hi > lo {
            focusRange = Double(lo)...Double(hi)
            focusPosition = Double(cur)
        }
        if let cur = uvc.getCT(.exposureTimeAbsolute),
           let lo = uvc.getCT(.exposureTimeAbsolute, request: .getMin),
           let hi = uvc.getCT(.exposureTimeAbsolute, request: .getMax),
           hi > lo {
            exposureRange = Double(lo)...Double(hi)
            exposureTime = Double(cur)
        }
    }

    // MARK: - Setters (AVFoundation)

    func applyFormat(_ index: Int) {
        guard let cam = controller, formats.indices.contains(index) else { return }
        do {
            try cam.avf.setFormat(index: index)
            supportedFPS = formats[index].fps
            let live = Int(cam.avf.currentFPS.rounded())
            fps = supportedFPS.contains(live) ? live : (supportedFPS.first ?? 30)
            if !supportedFPS.contains(live), let f = supportedFPS.first {
                try? cam.avf.setFPS(Double(f))
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyFPS(_ rate: Int) {
        guard let cam = controller else { return }
        do { try cam.avf.setFPS(Double(rate)) }
        catch { errorMessage = error.localizedDescription }
    }

    func applyFocusMode() {
        guard let cam = controller else { return }
        do {
            if focusAuto { try cam.avf.setFocusAuto() }
            else { try cam.avf.setFocusLocked() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func applyExposureMode() {
        guard let cam = controller else { return }
        // AVFoundation auto/locked is reliable; the UVC AE mode write is what
        // actually puts the camera into manual mode so exposureTimeAbsolute
        // writes take effect on this external UVC device.
        do {
            if exposureAuto { try cam.avf.setExposureAuto() }
            else { try cam.avf.setExposureLocked() }
        } catch {
            errorMessage = error.localizedDescription
        }
        if let uvc = cam.uvc {
            let mode: AEMode = exposureAuto ? .auto : .manual
            report { try uvc.setCT(.autoExposureMode, value: Int(mode.rawValue)) }
        }
    }

    // MARK: - Setters (UVC)

    func commitPU(_ ctrl: PUControl) {
        guard let uvc = controller?.uvc, let v = puValues[ctrl] else { return }
        report { try uvc.setPU(ctrl, value: Int16(v.rounded())) }
    }

    func applyWBAuto() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setPU(.whiteBalanceTempAuto, value: wbAuto ? 1 : 0) }
    }

    func commitZoom() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setCT(.zoomAbsolute, value: Int(zoomValue.rounded())) }
    }

    func commitFocusPosition() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setCT(.focusAbsolute, value: Int(focusPosition.rounded())) }
    }

    func commitExposureTime() {
        guard let uvc = controller?.uvc else { return }
        report { try uvc.setCT(.exposureTimeAbsolute, value: Int(exposureTime.rounded())) }
    }

    private func report(_ work: () throws -> Void) {
        do {
            try work()
            if errorMessage != nil { errorMessage = nil }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
