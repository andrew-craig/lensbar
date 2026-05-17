import AppKit
import SwiftUI

public struct ContentView: View {
    @EnvironmentObject var camera: CameraViewModel

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                preview

                VStack(alignment: .leading, spacing: 14) {
                    if let err = camera.errorMessage {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !camera.cameraInUse {
                        avfSection
                        Divider()
                    }
                    if camera.hasUVC {
                        uvcSection
                        Divider()
                        cameraTerminalSection
                        Divider()
                    }
                    Button("Quit") { NSApp.terminate(nil) }
                        .frame(maxWidth: .infinity)
                }
                .padding(12)
            }
            .frame(width: 400, alignment: .leading)
        }
        .frame(width: 400, height: 560)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Preview

    private var preview: some View {
        ZStack {
            CameraPreview(session: camera.session)
            if camera.cameraInUse {
                Color.black
                Text("Camera is in use by another app")
                    .font(.callout)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
            }
        }
        .frame(height: 225)
    }

    // MARK: - AVFoundation section

    private var avfSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                Picker("Format", selection: $camera.formatIndex) {
                    ForEach(camera.formats, id: \.index) { fmt in
                        Text(verbatim: "\(fmt.width)×\(fmt.height)").tag(fmt.index)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: camera.formatIndex) { new in camera.applyFormat(new) }

                Picker("FPS", selection: $camera.fps) {
                    ForEach(camera.supportedFPS, id: \.self) { f in
                        Text("\(f)").tag(f)
                    }
                }
                .pickerStyle(.menu)
                .onChange(of: camera.fps) { new in camera.applyFPS(new) }
            }

            HStack(spacing: 8) {
                Toggle("Auto Focus", isOn: $camera.focusAuto)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!camera.focusAutoSupported)
                    .onChange(of: camera.focusAuto) { _ in camera.applyFocusMode() }

                if !camera.focusAuto,
                    camera.focusRange.upperBound > camera.focusRange.lowerBound
                {
                    Slider(
                        value: $camera.focusPosition,
                        in: camera.focusRange,
                        onEditingChanged: { editing in
                            if !editing { camera.commitFocusPosition() }
                        }
                    )
                    Text(verbatim: "\(Int(camera.focusPosition.rounded()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }

            HStack(spacing: 8) {
                Toggle("Auto Exposure", isOn: $camera.exposureAuto)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!camera.exposureAutoSupported)
                    .onChange(of: camera.exposureAuto) { _ in camera.applyExposureMode() }

                if !camera.exposureAuto,
                    camera.exposureRange.upperBound > camera.exposureRange.lowerBound
                {
                    Slider(
                        value: $camera.exposureTime,
                        in: camera.exposureRange,
                        onEditingChanged: { editing in
                            if !editing { camera.commitExposureTime() }
                        }
                    )
                    Text(String(format: "%.1f ms", camera.exposureTime / 10))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - UVC PU sliders

    private var uvcSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CameraViewModel.sliderControls, id: \.self) { ctrl in
                if ctrl != .whiteBalanceTemperature, let range = camera.puRanges[ctrl] {
                    sliderRow(
                        label: ctrl.displayName,
                        value: Binding(
                            get: { camera.puValues[ctrl] ?? range.lowerBound },
                            set: { camera.puValues[ctrl] = $0 }
                        ),
                        range: range,
                        commit: { camera.commitPU(ctrl) },
                        disabled: false
                    )
                }
            }

            HStack(spacing: 8) {
                Toggle("Auto White Balance", isOn: $camera.wbAuto)
                    .toggleStyle(.switch)
                    .fixedSize()
                    .disabled(!camera.wbAutoSupported)
                    .onChange(of: camera.wbAuto) { _ in camera.applyWBAuto() }

                if !camera.wbAuto, let range = camera.puRanges[.whiteBalanceTemperature] {
                    Slider(
                        value: Binding(
                            get: { camera.puValues[.whiteBalanceTemperature] ?? range.lowerBound },
                            set: { camera.puValues[.whiteBalanceTemperature] = $0 }
                        ),
                        in: range,
                        onEditingChanged: { editing in
                            if !editing { camera.commitPU(.whiteBalanceTemperature) }
                        }
                    )
                    Text(verbatim: "\(Int((camera.puValues[.whiteBalanceTemperature] ?? range.lowerBound).rounded()))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: - UVC CT sliders

    private var cameraTerminalSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if camera.zoomRange.upperBound > camera.zoomRange.lowerBound {
                sliderRow(
                    label: "Zoom",
                    value: $camera.zoomValue,
                    range: camera.zoomRange,
                    commit: { camera.commitZoom() },
                    disabled: false
                )
            }
        }
    }

    // MARK: - Slider row

    private func sliderRow(
        label: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        commit: @escaping () -> Void,
        disabled: Bool,
        format: ((Double) -> String)? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                    .font(.caption)
                Spacer()
                Text(verbatim: format?(value.wrappedValue.rounded()) ?? "\(Int(value.wrappedValue.rounded()))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(
                value: value,
                in: range,
                onEditingChanged: { editing in
                    if !editing { commit() }
                }
            )
        }
        .disabled(disabled)
    }
}
