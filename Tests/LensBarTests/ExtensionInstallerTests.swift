import Foundation
import SystemExtensions
import Testing
@testable import LensBarCore

private let v1 = ExtensionVersion(shortVersion: "1.2.0", bundleVersion: "40")
private let v2 = ExtensionVersion(shortVersion: "1.3.0", bundleVersion: "41")

private func record(_ version: ExtensionVersion = v1, enabled: Bool = false,
                    awaiting: Bool = false, uninstalling: Bool = false) -> ExtensionRecord {
    ExtensionRecord(version: version, isEnabled: enabled,
                    isAwaitingUserApproval: awaiting, isUninstalling: uninstalling)
}

@Suite("ExtensionStatus")
struct ExtensionStatusTests {
    @Test("No records means not installed")
    func empty() {
        #expect(ExtensionStatus.derive(from: []) == .notInstalled)
    }

    @Test("An enabled record is installed, with its version")
    func enabled() {
        #expect(ExtensionStatus.derive(from: [record(v2, enabled: true)]) == .installed(v2))
    }

    @Test("Awaiting approval")
    func awaiting() {
        #expect(ExtensionStatus.derive(from: [record(awaiting: true)]) == .needsApproval)
    }

    @Test("Only uninstalling builds count as not installed")
    func uninstalling() {
        #expect(ExtensionStatus.derive(from: [record(enabled: true, uninstalling: true)]) == .notInstalled)
    }

    @Test("An old build uninstalling next to the enabled new one")
    func upgradeInProgress() {
        let records = [record(v1, enabled: true, uninstalling: true), record(v2, enabled: true)]
        #expect(ExtensionStatus.derive(from: records) == .installed(v2))
    }

    @Test("Enabled wins over awaiting approval")
    func enabledWins() {
        let records = [record(v2, awaiting: true), record(v1, enabled: true)]
        #expect(ExtensionStatus.derive(from: records) == .installed(v1))
    }

    @Test("Version reads from an Info.plist dictionary")
    func versionFromInfo() {
        let info: [String: Any] = ["CFBundleShortVersionString": "1.2.0", "CFBundleVersion": "40"]
        #expect(ExtensionVersion(infoDictionary: info) == v1)
        #expect(ExtensionVersion(infoDictionary: ["CFBundleVersion": "40"]) == nil)
        #expect(ExtensionVersion(infoDictionary: nil) == nil)
    }
}

private func replaces(_ existing: ExtensionRecord, with bundled: ExtensionVersion, always: Bool = false) -> Bool {
    ExtensionReplacementPolicy.shouldReplace(existing: existing, with: bundled, alwaysReplace: always)
}

@Suite("ExtensionReplacementPolicy")
struct ExtensionReplacementPolicyTests {
    @Test("A different build replaces the installed one")
    func differentVersion() {
        #expect(replaces(record(v1, enabled: true), with: v2))
        let sameShort = ExtensionVersion(shortVersion: "1.2.0", bundleVersion: "41")
        #expect(replaces(record(v1, enabled: true), with: sameShort))
    }

    @Test("An identical enabled build is kept so live calls aren't cut")
    func identicalKept() {
        #expect(!replaces(record(v1, enabled: true), with: v1))
    }

    @Test("An identical build that isn't enabled yet is replaced")
    func identicalNotEnabled() {
        #expect(replaces(record(v1, awaiting: true), with: v1))
    }

    @Test("Debug builds always replace")
    func alwaysReplace() {
        #expect(replaces(record(v1, enabled: true), with: v1, always: true))
    }

    @Test("Upgrade at launch only for an installed, different build")
    func needsUpgrade() {
        #expect(ExtensionReplacementPolicy.needsUpgrade(status: .installed(v1), bundled: v2))
        #expect(!ExtensionReplacementPolicy.needsUpgrade(status: .installed(v2), bundled: v2))
        #expect(!ExtensionReplacementPolicy.needsUpgrade(status: .installed(v1), bundled: nil))
        // Opt-in: never installs or approves on the user's behalf.
        #expect(!ExtensionReplacementPolicy.needsUpgrade(status: .notInstalled, bundled: v2))
        #expect(!ExtensionReplacementPolicy.needsUpgrade(status: .needsApproval, bundled: v2))
        #expect(!ExtensionReplacementPolicy.needsUpgrade(status: .unknown, bundled: v2))
    }
}

@Suite("ExtensionInstaller helpers")
struct ExtensionInstallerHelperTests {
    @Test("Install location: only under /Applications")
    func location() {
        #expect(ExtensionInstallLocation.isSupported(appPath: "/Applications/LensBar.app"))
        #expect(ExtensionInstallLocation.isSupported(appPath: "/Applications/Utilities/LensBar.app"))
        #expect(!ExtensionInstallLocation.isSupported(appPath: "/Users/me/DerivedData/LensBar.app"))
        #expect(!ExtensionInstallLocation.isSupported(appPath: "/Applications/../tmp/LensBar.app"))
        #expect(!ExtensionInstallLocation.isSupported(appPath: "/ApplicationsX/LensBar.app"))
    }

    @Test("Approval pane by macOS version")
    func approvalPane() {
        #expect(ExtensionApprovalPane.url(macOSMajor: 15).absoluteString.contains("LoginItems-Settings.extension"))
        #expect(ExtensionApprovalPane.url(macOSMajor: 26).absoluteString.contains("LoginItems-Settings.extension"))
        #expect(ExtensionApprovalPane.url(macOSMajor: 14).absoluteString.contains("com.apple.preference.security"))
        #expect(ExtensionApprovalPane.instructions(macOSMajor: 15).contains("Camera Extensions"))
        #expect(ExtensionApprovalPane.instructions(macOSMajor: 14).contains("Privacy & Security"))
    }

    @Test("Cancelled and superseded requests aren't errors")
    func silentFailures() {
        #expect(ExtensionInstaller.message(for: .requestCanceled, removing: false, fallback: "x") == nil)
        #expect(ExtensionInstaller.message(for: .requestSuperseded, removing: true, fallback: "x") == nil)
    }

    @Test("Failures map to actionable text")
    func messages() {
        #expect(ExtensionInstaller.message(for: .unsupportedParentBundleLocation, removing: false, fallback: "x")?
            .contains("Applications") == true)
        #expect(ExtensionInstaller.message(for: .missingEntitlement, removing: false, fallback: "x")?
            .contains("signed") == true)
        let removeFailed = ExtensionInstaller.message(for: .unknown, removing: true, fallback: "boom")
        #expect(removeFailed == "Couldn't remove LensBar Camera: boom")
        let installFailed = ExtensionInstaller.message(for: nil, removing: false, fallback: "boom")
        #expect(installFailed == "Couldn't install LensBar Camera: boom")
    }

    @Test("Without an embedded extension there's nothing to install")
    @MainActor
    func notEmbedded() {
        let installer = ExtensionInstaller(bundle: Bundle(for: BundleToken.self))
        #expect(installer.bundledVersion == nil)
        installer.refresh()
        #expect(installer.status == .notInstalled)
    }
}

private final class BundleToken {}
