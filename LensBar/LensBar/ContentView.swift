import SwiftUI
import LensBar  // the package module

@main
struct LensBarAppEntry: App {
    var body: some Scene {
        // delegate to the SwiftUI types that already live in the package
        LensBarApp().body
    }
}
