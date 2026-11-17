import Foundation

/// Custom CMIO device properties LensBar Camera exposes to the app.
///
/// A CMIO extension declares a custom property as a `CMIOExtensionProperty`
/// whose raw value is `"4cc_<selector>_<scope>_<element>"`. Clients reach it
/// through the CMIO C API with a `CMIOObjectPropertyAddress` whose selector is
/// the same four-character code, global scope, element 0. Values are strings
/// (CFString on the C side), which the spike showed work in both directions
/// and with `notifyPropertiesChanged` (PLAN.md §6, Phase 0 results).
public enum VirtualCameraProperty: String, CaseIterable, Sendable {
    /// Read-only. Number of running source-stream clients (Zoom etc.), encoded
    /// with `ClientCountCodec`. The extension pushes changes with
    /// `notifyPropertiesChanged`, so the app can listen instead of polling.
    case clientCount = "lbcc"

    /// Read/write. A `VirtualCameraFormat` in its string form.
    /// - Write: the app pushes LensBar's current resolution and frame rate.
    ///   The extension remembers it and advertises it from the next time it
    ///   has zero clients (PLAN.md §4.5).
    /// - Read: the format currently advertised to clients.
    case format = "lbfm"

    /// Four-character code as a string, e.g. `"lbcc"`.
    public var fourCCString: String { rawValue }

    /// Selector for `CMIOObjectPropertyAddress.mSelector`.
    public var selector: UInt32 {
        rawValue.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }

    /// Raw value for `CMIOExtensionProperty(rawValue:)` in the extension.
    public var extensionPropertyName: String { "4cc_\(rawValue)_glob_0000" }
}

/// String encoding of the client-count property.
public enum ClientCountCodec {
    public static func encode(_ count: Int) -> String { String(max(0, count)) }

    /// Nil for anything that isn't a non-negative integer.
    public static func decode(_ string: String) -> Int? {
        guard let n = Int(string.trimmingCharacters(in: .whitespaces)), n >= 0 else { return nil }
        return n
    }
}
