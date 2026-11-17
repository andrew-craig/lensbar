import Foundation

/// Remembers the last format the app pushed, so the extension advertises
/// LensBar's resolution and frame rate even when it starts while the app is
/// not running (PLAN.md §6, Phase 2).
///
/// The extension is sandboxed, so `UserDefaults.standard` lives in its own
/// container. The value is stored in `VirtualCameraFormat`'s string form; an
/// unreadable value falls back to `VirtualCameraFormat.default`.
public struct FormatStore {
    public static let key = "VirtualCameraAdvertisedFormat"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The remembered format, or nil if none or unreadable.
    public func load() -> VirtualCameraFormat? {
        defaults.string(forKey: Self.key).flatMap(VirtualCameraFormat.init(encoded:))
    }

    public func loadOrDefault() -> VirtualCameraFormat {
        load() ?? .default
    }

    public func save(_ format: VirtualCameraFormat) {
        defaults.set(format.encoded, forKey: Self.key)
    }
}
