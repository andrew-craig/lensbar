import CoreMedia
import CoreMediaIO
import Foundation

/// One stream of LensBar Camera: the source (what clients read) or the sink
/// (what the app writes). Each advertises exactly one format with exactly one
/// frame rate (PLAN.md §4.5).
///
/// `generation` ties the stream to one build of the device. After a device
/// replacement, late callbacks from the old streams carry a stale generation
/// and the device ignores them.
final class CameraStreamSource: NSObject, CMIOExtensionStreamSource, @unchecked Sendable {
    private(set) var stream: CMIOExtensionStream!
    let generation: Int
    private let format: CMIOExtensionStreamFormat
    private let frameDuration: CMTime
    private let direction: CMIOExtensionStream.Direction
    private unowned let owner: CameraDeviceSource

    private let lock = NSLock()
    private var pendingClient: CMIOExtensionClient?

    init(localizedName: String, streamID: UUID, direction: CMIOExtensionStream.Direction,
         format: CMIOExtensionStreamFormat, frameDuration: CMTime,
         generation: Int, owner: CameraDeviceSource) {
        self.format = format
        self.frameDuration = frameDuration
        self.direction = direction
        self.generation = generation
        self.owner = owner
        super.init()
        stream = CMIOExtensionStream(localizedName: localizedName, streamID: streamID,
                                     direction: direction, clockType: .hostTime, source: self)
    }

    var formats: [CMIOExtensionStreamFormat] { [format] }

    var availableProperties: Set<CMIOExtensionProperty> {
        var props: Set<CMIOExtensionProperty> = [.streamActiveFormatIndex, .streamFrameDuration]
        if direction == .sink {
            props.formUnion([.streamSinkBufferQueueSize, .streamSinkBuffersRequiredForStartup,
                             .streamSinkBufferUnderrunCount, .streamSinkEndOfData])
        }
        return props
    }

    func streamProperties(
        forProperties properties: Set<CMIOExtensionProperty>
    ) throws -> CMIOExtensionStreamProperties {
        let props = CMIOExtensionStreamProperties(dictionary: [:])
        if properties.contains(.streamActiveFormatIndex) { props.activeFormatIndex = 0 }
        if properties.contains(.streamFrameDuration) { props.frameDuration = frameDuration }
        if direction == .sink {
            if properties.contains(.streamSinkBufferQueueSize) { props.sinkBufferQueueSize = 4 }
            if properties.contains(.streamSinkBuffersRequiredForStartup) { props.sinkBuffersRequiredForStartup = 1 }
        }
        return props
    }

    /// There is only one format and one frame rate, so there is nothing for a
    /// client to change. Ignore the request rather than fail it.
    func setStreamProperties(_ streamProperties: CMIOExtensionStreamProperties) throws {}

    func authorizedToStartStream(for client: CMIOExtensionClient) -> Bool {
        lock.withLock { pendingClient = client }
        return true
    }

    func startStream() throws {
        switch direction {
        case .source:
            owner.sourceStarted(generation: generation)
        case .sink:
            guard let client = lock.withLock({ pendingClient }) else {
                throw CameraExtensionError.noSinkClient
            }
            owner.sinkStarted(client: client, generation: generation)
        @unknown default:
            break
        }
    }

    func stopStream() throws {
        switch direction {
        case .source: owner.sourceStopped(generation: generation)
        case .sink: owner.sinkStopped(generation: generation)
        @unknown default: break
        }
    }
}
