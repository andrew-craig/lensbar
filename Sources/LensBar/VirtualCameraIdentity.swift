import Foundation

/// Identity of LensBar's own virtual camera ("LensBar Camera", PLAN.md §5).
///
/// The camera extension publishes its device with this fixed `deviceID`, and
/// AVFoundation surfaces a CMIO extension device with `uniqueID` equal to that
/// UUID's string form. LensBar must never offer it in its own picker, or it
/// could end up capturing itself.
///
/// Phase 2 moves this into `VirtualCameraKit` so the sandboxed extension can
/// share the constant.
public enum VirtualCameraIdentity {
    /// `CMIOExtensionDevice.deviceID` of LensBar Camera, as a UUID string.
    public static let deviceUID = "A9C505F2-02CB-4A5C-ACEB-1D67B4D733F3"

    /// User-visible device name the extension publishes.
    public static let deviceName = "LensBar Camera"

    /// Whether an `AVCaptureDevice.uniqueID` belongs to LensBar's own virtual
    /// camera. UUID strings compare case-insensitively.
    static func isOwnDevice(uniqueID: String) -> Bool {
        uniqueID.caseInsensitiveCompare(deviceUID) == .orderedSame
    }

    /// Drop LensBar's own virtual camera from a device list.
    static func excludingOwnDevice<T>(_ devices: [T], uniqueID: (T) -> String) -> [T] {
        devices.filter { !isOwnDevice(uniqueID: uniqueID($0)) }
    }
}
