import Foundation

/// The one format LensBar Camera advertises: resolution, pixel format and a
/// single frame rate (PLAN.md §4.5). The app sends it to the extension as a
/// string through `VirtualCameraProperty.format`, and the extension persists
/// it in the same form.
///
/// String form: `"<width>x<height>@<num>/<den> <pixelFormat>"`, for example
/// `"1280x720@25/1 420v"` or `"1920x1080@30000/1001 420v"`. The frame rate is
/// the rational `num / den` frames per second, so the frame duration is
/// exactly `den / num` seconds (`CMTime(value: den, timescale: num)`).
public struct VirtualCameraFormat: Equatable, Hashable, Sendable, CustomStringConvertible {
    public var width: Int32
    public var height: Int32
    /// Frame rate numerator (frames).
    public var fpsNumerator: Int32
    /// Frame rate denominator (seconds).
    public var fpsDenominator: Int32
    /// CoreVideo pixel format four-character code. Only NV12 video range
    /// (`'420v'`, `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`) is used.
    public var pixelFormat: UInt32

    /// `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange` without importing CoreVideo.
    public static let nv12VideoRange: UInt32 = 0x3432_3076 // '420v'

    public static let supportedPixelFormats: Set<UInt32> = [nv12VideoRange]

    /// Limits accepted from the property, so a bad write can't make the
    /// extension allocate something absurd.
    public static let dimensionRange: ClosedRange<Int32> = 16...8192
    public static let fpsRange: ClosedRange<Double> = 1...240

    /// What the extension advertises before the app has ever pushed a format.
    public static let `default` = VirtualCameraFormat(width: 1280, height: 720, fpsNumerator: 30, fpsDenominator: 1)

    public init(width: Int32, height: Int32, fpsNumerator: Int32, fpsDenominator: Int32 = 1,
                pixelFormat: UInt32 = VirtualCameraFormat.nv12VideoRange) {
        self.width = width
        self.height = height
        self.fpsNumerator = fpsNumerator
        self.fpsDenominator = fpsDenominator
        self.pixelFormat = pixelFormat
    }

    /// Build from LensBar's settings, where the frame rate is a `Double` taken
    /// from `AVFrameRateRange`. NTSC rates (29.97, 59.94, 23.976, ...) map to
    /// `n*1000/1001`; anything else rounds to a whole number of frames per
    /// second. Returns nil when the result is out of range.
    public init?(width: Int, height: Int, fps: Double,
                 pixelFormat: UInt32 = VirtualCameraFormat.nv12VideoRange) {
        guard fps.isFinite, fps > 0,
              let w = Int32(exactly: width), let h = Int32(exactly: height) else { return nil }
        let (num, den) = Self.rational(fps: fps)
        self.init(width: w, height: h, fpsNumerator: num, fpsDenominator: den, pixelFormat: pixelFormat)
        guard isValid else { return nil }
    }

    public var framesPerSecond: Double { Double(fpsNumerator) / Double(fpsDenominator) }

    /// Frame duration as a `CMTime`-style `(value, timescale)` pair.
    public var frameDuration: (value: Int64, timescale: Int32) { (Int64(fpsDenominator), fpsNumerator) }

    public var isValid: Bool {
        Self.dimensionRange.contains(width) && Self.dimensionRange.contains(height)
            // NV12 subsamples chroma 2x2.
            && width % 2 == 0 && height % 2 == 0
            && fpsNumerator > 0 && fpsDenominator > 0
            && Self.fpsRange.contains(framesPerSecond)
            && Self.supportedPixelFormats.contains(pixelFormat)
    }

    // MARK: String codec

    public var encoded: String {
        "\(width)x\(height)@\(fpsNumerator)/\(fpsDenominator) \(Self.fourCCString(pixelFormat))"
    }

    public var description: String { encoded }

    /// Parse the string form. Returns nil if it is malformed or not `isValid`.
    public init?(encoded string: String) {
        let parts = string.trimmingCharacters(in: .whitespaces).split(separator: " ")
        guard parts.count == 2, let pixelFormat = Self.fourCC(parts[1]) else { return nil }
        let sizeAndRate = parts[0].split(separator: "@")
        guard sizeAndRate.count == 2 else { return nil }
        let size = sizeAndRate[0].split(separator: "x")
        let rate = sizeAndRate[1].split(separator: "/")
        guard size.count == 2, rate.count == 2,
              let w = Int32(size[0]), let h = Int32(size[1]),
              let num = Int32(rate[0]), let den = Int32(rate[1]) else { return nil }
        self.init(width: w, height: h, fpsNumerator: num, fpsDenominator: den, pixelFormat: pixelFormat)
        guard isValid else { return nil }
    }

    // MARK: Helpers

    static func rational(fps: Double) -> (Int32, Int32) {
        let ntsc = (fps * 1.001).rounded()
        if abs(fps - ntsc * 1000 / 1001) < 0.005, abs(fps - ntsc) > 0.005, ntsc * 1000 < Double(Int32.max) {
            return (Int32(ntsc) * 1000, 1001)
        }
        let whole = fps.rounded()
        return (Int32(clamping: Int64(max(whole, 0))), 1)
    }

    static func fourCCString(_ code: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> UInt32($0)) & 0xFF) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func fourCC<S: StringProtocol>(_ s: S) -> UInt32? {
        let bytes = Array(s.utf8)
        guard bytes.count == 4, bytes.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return bytes.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
