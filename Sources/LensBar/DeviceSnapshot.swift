import Foundation

/// Persisted per-device UI state. Replayed on launch so the camera comes up
/// with the user's last-known settings instead of UVC firmware defaults.
///
/// Stored as JSON in `UserDefaults` keyed by `AVCaptureDevice.uniqueID`. All
/// fields are optional so older saved blobs decode cleanly as the schema grows.
///
/// Format identity is stored as `(width, height, pixelFormat)` rather than an
/// index into `device.formats`. Indexes are not stable across firmware updates
/// or driver revisions; the dimensions+subtype tuple is.
struct DeviceSnapshot: Codable, Equatable {
    var formatWidth: Int32?
    var formatHeight: Int32?
    var formatPixelFormat: UInt32?
    var fps: Int?
    var focusAuto: Bool?
    var exposureAuto: Bool?

    /// PUControl.rawValue (stringified) → current value. Stringified keys are
    /// required because JSONEncoder rejects non-string dictionary keys.
    var puValues: [String: Int]?
    /// CTControl.rawValue (stringified) → current value.
    var ctValues: [String: Int]?

    static func load(forDeviceID id: String) -> DeviceSnapshot? {
        let key = defaultsKey(for: id)
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(DeviceSnapshot.self, from: data)
    }

    func save(forDeviceID id: String) {
        let key = Self.defaultsKey(for: id)
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    private static func defaultsKey(for id: String) -> String {
        "lensbar.deviceSnapshot.\(id)"
    }
}

extension DeviceSnapshot {
    func pu(_ control: PUControl) -> Int? { puValues?[String(control.rawValue)] }
    func ct(_ control: CTControl) -> Int? { ctValues?[String(control.rawValue)] }

    mutating func setPU(_ control: PUControl, _ value: Int) {
        var map = puValues ?? [:]
        map[String(control.rawValue)] = value
        puValues = map
    }

    mutating func setCT(_ control: CTControl, _ value: Int) {
        var map = ctValues ?? [:]
        map[String(control.rawValue)] = value
        ctValues = map
    }
}
