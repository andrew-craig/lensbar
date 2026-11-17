import CoreMediaIO
import Foundation

/// Thin wrappers over the CoreMediaIO C API, as used by the app to reach
/// LensBar Camera (PLAN.md §6, Phase 0 results): find the device by UID, find
/// its sink stream by direction, and read/write/watch its custom string
/// properties.
///
/// Every call here is synchronous IPC to the CMIO server. They are cheap but
/// not free, so keep them off per-frame paths.
enum CMIOHardware {
    static let systemObject = CMIOObjectID(kCMIOObjectSystemObject)

    /// `kCMIOStreamPropertyDirection` value of a sink stream (data flows into
    /// the device). Source streams report 1.
    static let sinkDirection: UInt32 = 0

    static func address(_ selector: UInt32) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(mSelector: CMIOObjectPropertySelector(selector),
                                  mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                                  mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
    }

    static func address(_ selector: Int) -> CMIOObjectPropertyAddress {
        address(UInt32(selector))
    }

    /// Let this process see camera-extension and DAL devices through the C
    /// API. Idempotent.
    static func allowExtensionDevices() {
        var allow: UInt32 = 1
        var addr = address(kCMIOHardwarePropertyAllowScreenCaptureDevices)
        CMIOObjectSetPropertyData(systemObject, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &allow)
    }

    static func devices() -> [CMIOObjectID] {
        objectIDs(of: systemObject, selector: kCMIOHardwarePropertyDevices)
    }

    static func streams(of device: CMIOObjectID) -> [CMIOStreamID] {
        objectIDs(of: device, selector: kCMIODevicePropertyStreams)
    }

    static func deviceUID(of device: CMIOObjectID) -> String? {
        string(of: device, selector: UInt32(kCMIODevicePropertyDeviceUID))
    }

    static func direction(of stream: CMIOStreamID) -> UInt32? {
        var addr = address(kCMIOStreamPropertyDirection)
        var value: UInt32 = 0
        var used: UInt32 = 0
        let status = CMIOObjectGetPropertyData(stream, &addr, 0, nil,
                                               UInt32(MemoryLayout<UInt32>.size), &used, &value)
        return status == noErr ? value : nil
    }

    /// First device whose UID matches, compared case-insensitively.
    static func device(withUID uid: String) -> CMIOObjectID? {
        devices().first { deviceUID(of: $0)?.caseInsensitiveCompare(uid) == .orderedSame }
    }

    /// The device's sink stream, picked by direction (stream IDs change when
    /// the extension rebuilds its streams).
    static func sinkStream(of device: CMIOObjectID) -> CMIOStreamID? {
        VirtualCameraEndpoint.sinkStream(in: streams(of: device).map { ($0, direction(of: $0)) })
    }

    // MARK: String properties

    static func string(of object: CMIOObjectID, selector: UInt32) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var used: UInt32 = 0
        let size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    @discardableResult
    static func setString(_ string: String, of object: CMIOObjectID, selector: UInt32) -> OSStatus {
        var addr = address(selector)
        var value = string as CFString
        return withUnsafeMutablePointer(to: &value) { pointer in
            CMIOObjectSetPropertyData(object, &addr, 0, nil, UInt32(MemoryLayout<CFString>.size), pointer)
        }
    }

    // MARK: Listeners

    /// Register a listener block. The block runs on `queue`. CMIO only
    /// removes a listener given the identical block object, which Swift
    /// closures don't guarantee, so callers never remove: they ignore
    /// callbacks for objects they no longer care about instead.
    @discardableResult
    static func addListener(object: CMIOObjectID, selector: UInt32, queue: DispatchQueue,
                            _ block: @escaping () -> Void) -> OSStatus {
        var addr = address(selector)
        return CMIOObjectAddPropertyListenerBlock(object, &addr, queue) { _, _ in block() }
    }

    // MARK: Private

    private static func objectIDs(of object: CMIOObjectID, selector: Int) -> [CMIOObjectID] {
        var addr = address(selector)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(object, &addr, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(object, &addr, 0, nil, size, &used, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size))
    }
}

/// Where the app delivers frames: one CMIO device and its sink stream.
/// Both IDs can change when the extension restarts or replaces its device
/// after a format change, which is why the app compares endpoints rather
/// than holding on to the first one it found.
struct VirtualCameraEndpoint: Equatable, Sendable {
    let device: CMIOObjectID
    let sinkStream: CMIOStreamID

    /// Pick the sink stream from `(streamID, direction)` pairs. Streams whose
    /// direction can't be read are skipped.
    static func sinkStream(in streams: [(CMIOStreamID, UInt32?)]) -> CMIOStreamID? {
        streams.first { $0.1 == CMIOHardware.sinkDirection }?.0
    }
}
