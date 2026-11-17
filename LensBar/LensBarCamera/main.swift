// LensBar Camera: a CoreMediaIO camera extension (PLAN.md §5).
//
// The LensBar app captures the physical camera and pushes frames into this
// extension's sink stream; the extension forwards them to the source stream
// that Zoom, Meet, etc. read. It has no camera access and keeps no state other
// than the last format the app asked it to advertise.

import CoreMediaIO
import Foundation

let providerSource = CameraProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
