// Phase 0 spike host app (throwaway). Activates / deactivates the camera
// extension and shows the request status. Must run from /Applications.

import os
import SwiftUI
import SystemExtensions

let appLog = Logger(subsystem: "com.andrewcraig.LensBarSpike", category: "app")
let extensionID = "com.andrewcraig.LensBarSpike.Camera"

@MainActor
final class ExtensionManager: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    @Published var status = "idle"

    func activate() { submit(.activationRequest(forExtensionWithIdentifier: extensionID, queue: .main), "activate") }
    func deactivate() { submit(.deactivationRequest(forExtensionWithIdentifier: extensionID, queue: .main), "deactivate") }

    private func submit(_ req: OSSystemExtensionRequest, _ what: String) {
        req.delegate = self
        set("\(what): submitted")
        OSSystemExtensionManager.shared.submitRequest(req)
    }

    private func set(_ s: String) {
        status = s
        appLog.info("\(s, privacy: .public)")
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction {
        let msg = "replacing \(existing.bundleShortVersion)(\(existing.bundleVersion)) with \(ext.bundleShortVersion)(\(ext.bundleVersion))"
        Task { @MainActor in self.set(msg) }
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in
            self.set("needs approval: System Settings → General → Login Items & Extensions → Camera Extensions")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            self.set(result == .completed ? "completed" : "completed, reboot required")
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let ns = error as NSError
        Task { @MainActor in self.set("failed: \(ns.domain) \(ns.code) \(ns.localizedDescription)") }
    }
}

@main
struct SpikeApp: App {
    @StateObject private var manager = ExtensionManager()

    var body: some Scene {
        WindowGroup("LensBarSpike") {
            VStack(alignment: .leading, spacing: 12) {
                Text("Bundle: \(Bundle.main.bundlePath)").font(.caption).textSelection(.enabled)
                HStack {
                    Button("Activate") { manager.activate() }
                    Button("Deactivate") { manager.deactivate() }
                }
                Text(manager.status).textSelection(.enabled)
            }
            .padding()
            .frame(minWidth: 460)
            .onAppear {
                if CommandLine.arguments.contains("--activate") { manager.activate() }
            }
        }
    }
}
