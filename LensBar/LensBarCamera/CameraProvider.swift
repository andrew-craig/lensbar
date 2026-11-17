import CoreMediaIO
import Foundation
import os
import VirtualCameraKit

let extensionLog = Logger(subsystem: "com.lensbar", category: "extension")

enum CameraExtensionError: Error {
    /// The app wrote a format property value that doesn't parse or is out of range.
    case invalidFormat(String)
    /// A sink stream start arrived without an authorized client.
    case noSinkClient
}

/// Publishes the single "LensBar Camera" device.
final class CameraProviderSource: NSObject, CMIOExtensionProviderSource, @unchecked Sendable {
    private(set) var provider: CMIOExtensionProvider!
    private var deviceSource: CameraDeviceSource!

    init(clientQueue: DispatchQueue?) {
        super.init()
        provider = CMIOExtensionProvider(source: self, clientQueue: clientQueue)
        deviceSource = CameraDeviceSource(provider: provider, store: FormatStore())
        do {
            try provider.addDevice(deviceSource.device)
        } catch {
            fatalError("LensBar Camera: addDevice failed: \(error)")
        }
    }

    func connect(to client: CMIOExtensionClient) throws {
        extensionLog.info("client connected pid=\(client.pid) signingID=\(client.signingID ?? "?", privacy: .public)")
    }

    func disconnect(from client: CMIOExtensionClient) {
        extensionLog.info("client disconnected pid=\(client.pid)")
    }

    var availableProperties: Set<CMIOExtensionProperty> { [.providerManufacturer] }

    func providerProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionProviderProperties {
        let props = CMIOExtensionProviderProperties(dictionary: [:])
        if properties.contains(.providerManufacturer) {
            props.manufacturer = VirtualCameraIdentity.manufacturer
        }
        return props
    }

    func setProviderProperties(_ providerProperties: CMIOExtensionProviderProperties) throws {}
}
