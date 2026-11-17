import SwiftUI

/// "LensBar Camera" section of the popover (PLAN.md §6, Phase 4): install,
/// approval, status and removal of the virtual camera, plus Open at Login.
struct VirtualCameraSection: View {
    @EnvironmentObject var camera: CameraViewModel
    @EnvironmentObject var installer: ExtensionInstaller
    @EnvironmentObject var launchAtLogin: LaunchAtLogin

    @State private var confirmingRemove = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("LensBar Camera")
                    .font(.headline)
                Spacer()
                statusBadge
            }

            content

            if installer.restartRequired {
                caption("Restart your Mac to finish.", color: .orange)
            }
            if let error = installer.errorMessage {
                caption(error, color: .red)
            }
        }
        .onAppear {
            installer.refresh()
            launchAtLogin.refresh()
        }
        // The device appearing or vanishing usually means the registration
        // changed too (approved, removed, upgraded).
        .onChange(of: camera.virtualCameraAvailable) { _ in installer.refresh() }
    }

    // MARK: States

    @ViewBuilder
    private var content: some View {
        if let op = installer.operation {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(progressText(op)).font(.caption)
            }
            if op != .removing, installer.status == .needsApproval {
                approval
            }
        } else {
            switch installer.status {
            case .unknown:
                EmptyView()
            case .notInstalled:
                notInstalled
            case .needsApproval:
                approval
            case .installed:
                installed
            }
        }
    }

    private var notInstalled: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption("A virtual camera for Zoom, Meet, Teams or FaceTime. Call apps use it instead of your webcam, "
                    + "so they can't reset the format and frame rate set here. LensBar must be running.")
            if !installer.locationSupported {
                caption("Move LensBar to the Applications folder before installing.", color: .orange)
            }
            Button("Install LensBar Camera…") { installer.install() }
                .disabled(installer.bundledVersion == nil)
        }
    }

    private var approval: some View {
        VStack(alignment: .leading, spacing: 8) {
            caption(ExtensionApprovalPane.instructions(macOSMajor: ExtensionInstaller.macOSMajor))
            Button("Open System Settings") { installer.openApprovalSettings() }
        }
    }

    private var installed: some View {
        VStack(alignment: .leading, spacing: 8) {
            if camera.virtualCameraAvailable {
                usage
                caption("In your call app, select LensBar Camera before it shows a preview of your webcam. "
                        + "Apps that open the webcam directly reset its frame rate. "
                        + "Restart the app if LensBar Camera isn't listed.")
            } else {
                caption("Installed. Waiting for LensBar Camera to start…")
            }

            launchAtLoginRow

            if confirmingRemove {
                caption("Apps using LensBar Camera will lose video. macOS asks for your password.")
                HStack {
                    Button("Remove", role: .destructive) {
                        confirmingRemove = false
                        installer.remove()
                    }
                    Button("Cancel") { confirmingRemove = false }
                }
            } else {
                Button("Remove LensBar Camera…") { confirmingRemove = true }
            }
        }
    }

    @ViewBuilder
    private var usage: some View {
        let clients = camera.virtualCameraClients
        if clients > 0 {
            HStack(spacing: 6) {
                Text(clients == 1 ? "In use by 1 app" : "In use by \(clients) apps")
                    .font(.caption)
                if let actual = camera.actualFPS {
                    let drifted = abs(actual - Double(camera.fps)) > 1.0
                    Text(String(format: "· %.1f fps", actual))
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(drifted ? Color.orange : Color.secondary)
                }
            }
        } else {
            caption("Not in use.")
        }
    }

    @ViewBuilder
    private var launchAtLoginRow: some View {
        Toggle("Open LensBar at login", isOn: Binding(
            get: { launchAtLogin.isEnabled || launchAtLogin.needsApproval },
            set: { launchAtLogin.setEnabled($0) }
        ))
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.caption)
        if launchAtLogin.needsApproval {
            HStack(spacing: 6) {
                caption("LensBar is turned off in Login Items.", color: .orange)
                Button("Open Login Items") { launchAtLogin.openLoginItemsSettings() }
                    .controlSize(.small)
            }
        }
        if let error = launchAtLogin.errorMessage {
            caption(error, color: .red)
        }
    }

    // MARK: Pieces

    @ViewBuilder
    private var statusBadge: some View {
        let (text, color) = badge
        if !text.isEmpty {
            Text(text)
                .font(.caption2.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
    }

    private var badge: (String, Color) {
        if installer.operation != nil { return ("", .secondary) }
        switch installer.status {
        case .unknown, .notInstalled:
            return ("", .secondary)
        case .needsApproval:
            return ("Needs approval", .orange)
        case .installed:
            if !camera.virtualCameraAvailable { return ("Starting", .secondary) }
            return camera.virtualCameraClients > 0 ? ("Live", .green) : ("Ready", .blue)
        }
    }

    private func progressText(_ op: ExtensionInstaller.Operation) -> String {
        switch op {
        case .installing: return installer.status == .needsApproval ? "Waiting for approval…" : "Installing…"
        case .updating: return "Updating LensBar Camera…"
        case .removing: return "Removing…"
        }
    }

    private func caption(_ text: String, color: Color = .secondary) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }
}
