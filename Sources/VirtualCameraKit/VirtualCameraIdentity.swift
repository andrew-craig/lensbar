import Foundation

/// Identity of LensBar's own virtual camera ("LensBar Camera", PLAN.md §5),
/// shared by the app and the `LensBarCamera` system extension.
///
/// The camera extension publishes its device with this fixed `deviceID`, and
/// AVFoundation surfaces a CMIO extension device with `uniqueID` equal to that
/// UUID's string form. LensBar must never offer it in its own picker, or it
/// could end up capturing itself.
public enum VirtualCameraIdentity {
    /// `CMIOExtensionDevice.deviceID` of LensBar Camera, as a UUID string.
    /// Never changes, including across device replacement (PLAN.md §4.5).
    public static let deviceUID = "A9C505F2-02CB-4A5C-ACEB-1D67B4D733F3"

    /// Stream IDs used for the first set of streams an extension process
    /// builds. A removed stream ID can't be re-added to the same device, so
    /// streams built after a format change get fresh random IDs. The app must
    /// therefore find the sink stream by direction
    /// (`kCMIOStreamPropertyDirection == 0`), not by these IDs.
    public static let initialSourceStreamUID = "A9C505F2-02CB-4A5C-ACEB-1D67B4D733F4"
    public static let initialSinkStreamUID = "A9C505F2-02CB-4A5C-ACEB-1D67B4D733F5"

    /// User-visible device name the extension publishes.
    public static let deviceName = "LensBar Camera"

    /// Manufacturer string on the provider and device model.
    public static let manufacturer = "LensBar"

    /// Bundle identifier of the system extension, used by
    /// `OSSystemExtensionRequest` (Phase 4).
    public static let extensionBundleID = "com.andrewcraig.LensBar.Camera"

    /// Whether an `AVCaptureDevice.uniqueID` belongs to LensBar's own virtual
    /// camera. UUID strings compare case-insensitively.
    public static func isOwnDevice(uniqueID: String) -> Bool {
        uniqueID.caseInsensitiveCompare(deviceUID) == .orderedSame
    }

    /// Drop LensBar's own virtual camera from a device list.
    public static func excludingOwnDevice<T>(_ devices: [T], uniqueID: (T) -> String) -> [T] {
        devices.filter { !isOwnDevice(uniqueID: uniqueID($0)) }
    }
}
