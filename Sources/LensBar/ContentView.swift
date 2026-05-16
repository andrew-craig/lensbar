import SwiftUI
import AppKit

struct ContentView: View {
    @EnvironmentObject var camera: CameraViewModel

    var body: some View {
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

                    avfSection
                    Divider()
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
            .frame(width: 300, alignment: .leading)
        }
        .frame(width: 300, height: 560)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    // MARK: - Preview

    private var preview: some View {
        CameraPreview(session: camera.session)
            .frame(height: 169)
    }

    // MARK: - AVFoundation section

    private var avfSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Format", selection: $camera.formatIndex) {
                ForEach(camera.formats, id: \.index) { fmt in
                    Text("\(fmt.width)×\(fmt.height)").tag(fmt.index)
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

            Toggle("Auto Focus", isOn: $camera.focusAuto)
                .onChange(of: camera.focusAuto) { _ in camera.applyFocusMode() }

            Toggle("Auto Exposure", isOn: $camera.exposureAuto)
                .onChange(of: camera.exposureAuto) { _ in camera.applyExposureMode() }
        }
    }

    // MARK: - UVC PU sliders

    private var uvcSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(CameraViewModel.sliderControls, id: \.self) { ctrl in
                if let range = camera.puRanges[ctrl] {
                    sliderRow(
                        label: ctrl.displayName,
                        value: Binding(
                            get: { camera.puValues[ctrl] ?? range.lowerBound },
                            set: { camera.puValues[ctrl] = $0 }
                        ),
                        range: range,
                        commit: { camera.commitPU(ctrl) },
                        disabled: ctrl == .whiteBalanceTemperature && camera.wbAuto
                    )
                }
            }

            Toggle("Auto White Balance", isOn: $camera.wbAuto)
                .onChange(of: camera.wbAuto) { _ in camera.applyWBAuto() }
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
            if camera.focusRange.upperBound > camera.focusRange.lowerBound {
                sliderRow(
                    label: "Focus Position",
                    value: $camera.focusPosition,
                    range: camera.focusRange,
                    commit: { camera.commitFocusPosition() },
                    disabled: camera.focusAuto
                )
            }
            if camera.exposureRange.upperBound > camera.exposureRange.lowerBound {
                sliderRow(
                    label: "Exposure",
                    value: $camera.exposureTime,
                    range: camera.exposureRange,
                    commit: { camera.commitExposureTime() },
                    disabled: camera.exposureAuto,
                    format: { String(format: "%.1f ms", $0 / 10) }  // 100µs units → ms
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
                Text(format?(value.wrappedValue) ?? "\(Int(value.wrappedValue))")
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
