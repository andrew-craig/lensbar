import AppKit
import Foundation
import os
import SystemExtensions
import VirtualCameraKit

private let installerLog = Logger(subsystem: "com.andrewcraig.LensBar", category: "ExtensionInstaller")

/// Installs, upgrades and removes the LensBar Camera system extension through
/// `OSSystemExtensionRequest` (PLAN.md §5, §6 Phase 4), and tracks whether it
/// is registered and allowed.
///
/// The feature is opt-in: nothing is installed until `install()` is called.
/// At launch an already installed and allowed extension is replaced with the
/// build inside this app if the versions differ, so an app upgrade carries
/// the extension along without another approval.
///
/// Whether the device is actually up (and how many apps use it) comes from
/// `VirtualCameraCoordinator` instead; this only knows about registration.
@MainActor
public final class ExtensionInstaller: NSObject, ObservableObject {
    public enum Operation: Equatable, Sendable {
        case installing, updating, removing
    }

    @Published private(set) var status: ExtensionStatus = .unknown
    @Published private(set) var operation: Operation?
    @Published private(set) var errorMessage: String?
    /// An activation or removal finishes only after the Mac restarts.
    @Published private(set) var restartRequired = false

    /// Version of the extension embedded in this app, or nil when it isn't
    /// embedded (e.g. under `swift test`).
    let bundledVersion: ExtensionVersion?
    /// Whether the app runs from `/Applications` (see `ExtensionInstallLocation`).
    let locationSupported: Bool

    /// How often to re-read the registration while waiting for approval in
    /// System Settings. A request from an earlier launch never calls back, so
    /// this is how its approval is noticed.
    static let approvalPollInterval: Duration = .seconds(3)

    private let identifier = VirtualCameraIdentity.extensionBundleID
    private let alwaysReplace: Bool
    private var pending: [ObjectIdentifier: (request: OSSystemExtensionRequest, kind: Kind)] = [:]
    private var upgradeChecked = false
    private var started = false
    private var approvalPoll: Task<Void, Never>?

    private enum Kind { case properties, activate, deactivate }

    /// - Parameter alwaysReplace: replace an installed build even when its
    ///   version matches the bundled one. Pass `true` from Debug builds,
    ///   whose version numbers never change.
    public init(alwaysReplace: Bool = false, bundle: Bundle = .main) {
        self.alwaysReplace = alwaysReplace
        let extensionURL = bundle.bundleURL
            .appendingPathComponent("Contents/Library/SystemExtensions", isDirectory: true)
            .appendingPathComponent("\(VirtualCameraIdentity.extensionBundleID).systemextension", isDirectory: true)
        bundledVersion = Bundle(url: extensionURL).flatMap { ExtensionVersion(infoDictionary: $0.infoDictionary) }
        locationSupported = ExtensionInstallLocation.isSupported(appPath: bundle.bundlePath)
        super.init()
    }

    /// Read the registration and upgrade an installed extension if needed.
    /// Called once at app launch. Idempotent.
    public func start() {
        guard !started else { return }
        started = true
        refresh()
    }

    /// Re-read the registration from sysextd.
    public func refresh() {
        guard bundledVersion != nil else {
            status = .notInstalled
            return
        }
        guard !pending.values.contains(where: { $0.kind == .properties }) else { return }
        submit(.propertiesRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .properties)
    }

    public func install() {
        guard operation == nil else { return }
        guard bundledVersion != nil else {
            errorMessage = "LensBar Camera is missing from this copy of LensBar."
            return
        }
        activate(as: .installing)
    }

    public func remove() {
        guard operation == nil else { return }
        errorMessage = nil
        restartRequired = false
        operation = .removing
        installerLog.info("deactivation requested")
        submit(.deactivationRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .deactivate)
    }

    /// Open the System Settings pane where the extension is allowed.
    public func openApprovalSettings() {
        NSWorkspace.shared.open(ExtensionApprovalPane.url(macOSMajor: Self.macOSMajor))
    }

    static var macOSMajor: Int { ProcessInfo.processInfo.operatingSystemVersion.majorVersion }

    // MARK: Private

    private func activate(as op: Operation) {
        errorMessage = nil
        restartRequired = false
        operation = op
        installerLog.info("activation requested (\(op == .updating ? "update" : "install", privacy: .public))")
        submit(.activationRequest(forExtensionWithIdentifier: identifier, queue: .main), kind: .activate)
    }

    private func submit(_ request: OSSystemExtensionRequest, kind: Kind) {
        request.delegate = self
        pending[ObjectIdentifier(request)] = (request, kind)
        OSSystemExtensionManager.shared.submitRequest(request)
    }

    private func kind(of id: ObjectIdentifier) -> Kind? { pending[id]?.kind }

    private func setStatus(_ new: ExtensionStatus) {
        if new != status {
            installerLog.info("status \(String(describing: new), privacy: .public)")
            status = new
        }
        updateApprovalPoll()
        checkUpgradeOnce()
    }

    private func checkUpgradeOnce() {
        guard !upgradeChecked, status != .unknown else { return }
        upgradeChecked = true
        guard ExtensionReplacementPolicy.needsUpgrade(status: status, bundled: bundledVersion),
              operation == nil else { return }
        let bundled = bundledVersion?.description ?? "-"
        installerLog.info("installed build differs from bundled \(bundled, privacy: .public); updating")
        activate(as: .updating)
    }

    private func updateApprovalPoll() {
        let waiting = status == .needsApproval
        if waiting, approvalPoll == nil {
            approvalPoll = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: Self.approvalPollInterval)
                    self?.refresh()
                }
            }
        } else if !waiting {
            approvalPoll?.cancel()
            approvalPoll = nil
        }
    }

    fileprivate func handleProperties(_ id: ObjectIdentifier, records: [ExtensionRecord]) {
        pending[id] = nil
        setStatus(.derive(from: records))
    }

    fileprivate func handleNeedsApproval(_ id: ObjectIdentifier) {
        guard kind(of: id) == .activate else { return }
        installerLog.info("activation awaits user approval")
        // The request stays pending and finishes once the user allows it.
        setStatus(.needsApproval)
    }

    fileprivate func handleFinished(_ id: ObjectIdentifier, willCompleteAfterReboot: Bool) {
        guard let kind = kind(of: id) else { return }
        pending[id] = nil
        guard kind != .properties else { return }
        installerLog.info("request finished\(willCompleteAfterReboot ? " (after reboot)" : "", privacy: .public)")
        operation = nil
        restartRequired = willCompleteAfterReboot
        refresh()
    }

    fileprivate func handleFailed(_ id: ObjectIdentifier, code: Int, description: String) {
        guard let kind = kind(of: id) else { return }
        pending[id] = nil
        let errorCode = OSSystemExtensionError.Code(rawValue: code)
        switch kind {
        case .properties:
            if errorCode == .extensionNotFound {
                setStatus(.notInstalled)
            } else {
                installerLog.error("properties request failed: \(code) \(description, privacy: .public)")
                if status == .unknown { setStatus(.notInstalled) }
            }
        case .activate, .deactivate:
            installerLog.error("request failed: \(code) \(description, privacy: .public)")
            operation = nil
            errorMessage = Self.message(for: errorCode, removing: kind == .deactivate, fallback: description)
            refresh()
        }
    }

    fileprivate func replacementAction(existing: ExtensionRecord,
                                       bundled: ExtensionVersion) -> OSSystemExtensionRequest.ReplacementAction {
        let replace = ExtensionReplacementPolicy.shouldReplace(existing: existing, with: bundled,
                                                               alwaysReplace: alwaysReplace)
        let from = existing.version.description, to = bundled.description, verdict = replace ? "yes" : "no, keeping it"
        installerLog.info(
            "replace \(from, privacy: .public) with \(to, privacy: .public): \(verdict, privacy: .public)")
        return replace ? .replace : .cancel
    }

    /// User-facing text for a failed activation or deactivation, or nil when
    /// the failure isn't one (a kept identical build, a superseded request).
    nonisolated static func message(for code: OSSystemExtensionError.Code?, removing: Bool,
                                    fallback: String) -> String? {
        switch code {
        case .requestCanceled?, .requestSuperseded?:
            return nil
        case .unsupportedParentBundleLocation?:
            return "Move LensBar to the Applications folder, open it from there and try again."
        case .missingEntitlement?, .codeSignatureInvalid?, .validationFailed?:
            return "This copy of LensBar isn't signed to install LensBar Camera."
        case .extensionNotFound?, .extensionMissingIdentifier?:
            return removing ? "LensBar Camera isn't installed." : "LensBar Camera is missing from this copy of LensBar."
        case .authorizationRequired?:
            return (removing ? "Removal" : "Installing") + " needs your administrator password."
        case .forbiddenBySystemPolicy?:
            return "Your Mac's management settings don't allow LensBar Camera."
        default:
            return (removing ? "Couldn't remove LensBar Camera: " : "Couldn't install LensBar Camera: ") + fallback
        }
    }
}

// MARK: - OSSystemExtensionRequestDelegate

// Every request is created with `queue: .main`, so callbacks arrive on the
// main thread. Values are reduced to Sendable ones before hopping in.
extension ExtensionInstaller: OSSystemExtensionRequestDelegate {
    nonisolated public func request(_ request: OSSystemExtensionRequest,
                                    actionForReplacingExtension existing: OSSystemExtensionProperties,
                                    withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        let existingRecord = ExtensionRecord(existing)
        let bundled = ExtensionRecord(ext).version
        return MainActor.assumeIsolated { replacementAction(existing: existingRecord, bundled: bundled) }
    }

    nonisolated public func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        let id = ObjectIdentifier(request)
        MainActor.assumeIsolated { handleNeedsApproval(id) }
    }

    nonisolated public func request(_ request: OSSystemExtensionRequest,
                                    didFinishWithResult result: OSSystemExtensionRequest.Result) {
        let id = ObjectIdentifier(request)
        let afterReboot = result == .willCompleteAfterReboot
        MainActor.assumeIsolated { handleFinished(id, willCompleteAfterReboot: afterReboot) }
    }

    nonisolated public func request(_ request: OSSystemExtensionRequest, didFailWithError error: any Error) {
        let id = ObjectIdentifier(request)
        let nsError = error as NSError
        let code = nsError.domain == OSSystemExtensionErrorDomain
            ? nsError.code
            : OSSystemExtensionError.Code.unknown.rawValue
        let description = nsError.localizedDescription
        MainActor.assumeIsolated { handleFailed(id, code: code, description: description) }
    }

    nonisolated public func request(_ request: OSSystemExtensionRequest,
                                    foundProperties properties: [OSSystemExtensionProperties]) {
        let id = ObjectIdentifier(request)
        let records = properties.map(ExtensionRecord.init)
        MainActor.assumeIsolated { handleProperties(id, records: records) }
    }
}

extension ExtensionRecord {
    init(_ properties: OSSystemExtensionProperties) {
        self.init(version: ExtensionVersion(shortVersion: properties.bundleShortVersion,
                                            bundleVersion: properties.bundleVersion),
                  isEnabled: properties.isEnabled,
                  isAwaitingUserApproval: properties.isAwaitingUserApproval,
                  isUninstalling: properties.isUninstalling)
    }
}
