import Foundation
import os
import ServiceManagement

private let loginLog = Logger(subsystem: "com.andrewcraig.LensBar", category: "LaunchAtLogin")

/// Opens LensBar at login through `SMAppService.mainApp`. Offered with the
/// virtual camera: LensBar Camera only has video while the app runs, and
/// otherwise shows its placeholder (PLAN.md §4.3, §7).
@MainActor
public final class LaunchAtLogin: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var errorMessage: String?

    public init() {
        status = SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }
    /// Registered, but the user turned LensBar off in Login Items.
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        status = SMAppService.mainApp.status
    }

    func setEnabled(_ enabled: Bool) {
        errorMessage = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginLog.info("launch at login \(enabled ? "on" : "off", privacy: .public)")
        } catch {
            let state = enabled ? "on" : "off", reason = error.localizedDescription
            loginLog.error("launch at login \(state, privacy: .public) failed: \(reason, privacy: .public)")
            errorMessage = "Couldn't change Open at Login: \(error.localizedDescription)"
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
