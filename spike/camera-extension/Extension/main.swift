import CoreMediaIO
import Foundation

let providerSource = SpikeProviderSource(clientQueue: nil)
CMIOExtensionProvider.startService(provider: providerSource.provider)
CFRunLoopRun()
