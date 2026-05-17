import SwiftUI
import AppKit
import LensBarCore

@main
struct LensBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var camera = CameraViewModel()

    var body: some Scene {
        MenuBarExtra {
            ContentView()
                .environmentObject(camera)
        } label: {
            Image(systemName: "circle")
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
