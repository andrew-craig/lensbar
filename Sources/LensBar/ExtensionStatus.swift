import Foundation

/// Version of a system extension bundle: `CFBundleShortVersionString` and
/// `CFBundleVersion`. The release workflow stamps both on the app and the
/// extension (tag version and run number), so either differing means a
/// different build.
public struct ExtensionVersion: Equatable, Sendable, CustomStringConvertible {
    public var shortVersion: String
    public var bundleVersion: String

    public init(shortVersion: String, bundleVersion: String) {
        self.shortVersion = shortVersion
        self.bundleVersion = bundleVersion
    }

    /// Reads the two keys from an Info.plist dictionary.
    init?(infoDictionary: [String: Any]?) {
        guard let short = infoDictionary?["CFBundleShortVersionString"] as? String,
              let build = infoDictionary?["CFBundleVersion"] as? String else { return nil }
        self.init(shortVersion: short, bundleVersion: build)
    }

    public var description: String { "\(shortVersion) (\(bundleVersion))" }
}

/// One registration of the extension as reported by sysextd
/// (`OSSystemExtensionProperties`), reduced to what the decisions below need.
/// Several can exist at once, e.g. an old build waiting to uninstall next to
/// the new one.
struct ExtensionRecord: Equatable, Sendable {
    var version: ExtensionVersion
    var isEnabled: Bool
    var isAwaitingUserApproval: Bool
    var isUninstalling: Bool
}

/// Registration state of LensBar Camera, derived from sysextd's records.
enum ExtensionStatus: Equatable, Sendable {
    /// Not queried yet.
    case unknown
    /// Nothing registered (or only builds that are uninstalling).
    case notInstalled
    /// Registered, waiting for the user to allow it in System Settings.
    case needsApproval
    /// Registered and allowed.
    case installed(ExtensionVersion)

    static func derive(from records: [ExtensionRecord]) -> ExtensionStatus {
        let live = records.filter { !$0.isUninstalling }
        if let enabled = live.first(where: \.isEnabled) {
            return .installed(enabled.version)
        }
        if live.contains(where: \.isAwaitingUserApproval) {
            return .needsApproval
        }
        return .notInstalled
    }
}

/// Decisions around replacing an installed build (PLAN.md §6, Phase 4).
enum ExtensionReplacementPolicy {
    /// `actionForReplacingExtension`: replace when the bundled build differs,
    /// or when the installed one isn't running yet (nothing to disrupt).
    /// An identical, enabled build is kept: replacing it restarts the
    /// extension and cuts video in any call using LensBar Camera.
    ///
    /// `alwaysReplace` is for Debug builds, where every build has the same
    /// version numbers but different code.
    static func shouldReplace(existing: ExtensionRecord, with bundled: ExtensionVersion, alwaysReplace: Bool) -> Bool {
        alwaysReplace || existing.version != bundled || !existing.isEnabled
    }

    /// At launch: whether an installed, allowed extension should be upgraded
    /// to the build inside this app without asking. Never installs one the
    /// user didn't (the feature is opt-in), and leaves one awaiting approval
    /// to the user.
    static func needsUpgrade(status: ExtensionStatus, bundled: ExtensionVersion?) -> Bool {
        guard case .installed(let installed) = status, let bundled else { return false }
        return installed != bundled
    }
}

/// Where the user approves a camera extension.
enum ExtensionApprovalPane {
    /// macOS 15 moved camera extensions to Login Items & Extensions → Camera
    /// Extensions. macOS 14 asks in Privacy & Security ("System software from
    /// developer … was blocked").
    static func url(macOSMajor: Int) -> URL {
        if macOSMajor >= 15 {
            return URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?General")!
    }

    static func instructions(macOSMajor: Int) -> String {
        if macOSMajor >= 15 {
            return "In System Settings → General → Login Items & Extensions, scroll to Camera Extensions, "
                + "click (i), turn on LensBar Camera and enter your password. "
                + "If the switch doesn't stay on, turn it on again."
        }
        return "In System Settings → Privacy & Security, click Allow next to the message about "
            + "LensBar's system software and enter your password."
    }
}

/// Whether the app runs from a location sysextd accepts for activation.
/// Outside `/Applications` the request fails unless developer mode is on
/// (`systemextensionsctl developer on`), so this is a hint, not a gate.
enum ExtensionInstallLocation {
    static func isSupported(appPath: String) -> Bool {
        let standardized = (appPath as NSString).standardizingPath
        return standardized.hasPrefix("/Applications/")
    }
}
