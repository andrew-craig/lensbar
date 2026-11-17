import SwiftUI
import AppKit
import LensBarCore

@main
struct LensBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(appDelegate.camera)
                .environmentObject(appDelegate.installer)
                .environmentObject(appDelegate.launchAtLogin)
        } label: {
            Image("MenuBarIcon")
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here rather than by a view so it exists from launch: LensBar
    /// Camera clients must get video even if the popover is never opened.
    let camera = CameraViewModel()

    #if DEBUG
    /// Debug builds all share one version number, so always replace the
    /// installed extension with the one in this build.
    let installer = ExtensionInstaller(alwaysReplace: true)
    #else
    let installer = ExtensionInstaller()
    #endif

    let launchAtLogin = LaunchAtLogin()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        camera.startVirtualCamera()
        installer.start()
    }
}
