import Testing
@testable import LensBarCore

@Suite("CameraController.locationID parsing")
@MainActor
struct CameraControllerLocationIDTests {

    @Test("Plain 8-hex-digit location ID with 0x prefix")
    func parsesEightDigitWithPrefix() {
        #expect(CameraController.locationID(fromUniqueID: "0x14200000") == 0x14200000)
    }

    @Test("Plain 8-hex-digit location ID without prefix")
    func parsesEightDigitWithoutPrefix() {
        #expect(CameraController.locationID(fromUniqueID: "14200000") == 0x14200000)
    }

    @Test("Uppercase 0X prefix is accepted")
    func parsesUppercasePrefix() {
        #expect(CameraController.locationID(fromUniqueID: "0X14200000") == 0x14200000)
    }

    @Test("Location ID followed by VID+PID suffix strips the trailing 8 hex digits")
    func dropsVendorProductSuffix() {
        #expect(CameraController.locationID(fromUniqueID: "0x14200000046d082d") == 0x14200000)
        #expect(CameraController.locationID(fromUniqueID: "14200000046d082d") == 0x14200000)
    }

    @Test("Location ID with leading zeros recovers correctly after Apple's zero-stripping")
    func recoversLocationIDWithLeadingZeros() {
        // Opal C1: real IOKit locationID is 0x00200000 (VID=0x03e7, PID=0xf63d).
        // Full uniqueID would be 0x0020000003e7f63d but the runtime renders it as
        // 0x20000003e7f63d — only 14 hex digits because the leading zeros are
        // stripped. Dropping the trailing 8 (03e7f63d) leaves "200000", which
        // parses back to 0x00200000.
        #expect(CameraController.locationID(fromUniqueID: "0x20000003e7f63d") == 0x00200000)
        #expect(CameraController.locationID(fromUniqueID: "20000003e7f63d") == 0x00200000)
    }

    @Test("Short hex run is parsed as-is (no zero-padding)")
    func parsesShortHexRun() {
        #expect(CameraController.locationID(fromUniqueID: "0x1") == 0x1)
        #expect(CameraController.locationID(fromUniqueID: "abc") == 0xABC)
    }

    @Test("uniqueID with no leading hex digits returns nil")
    func returnsNilForUnparseable() {
        #expect(CameraController.locationID(fromUniqueID: "") == nil)
        #expect(CameraController.locationID(fromUniqueID: "0x") == nil)
        // Leading non-hex letter (g-z): no parseable prefix at all.
        #expect(CameraController.locationID(fromUniqueID: "not-a-hex-string") == nil)
        #expect(CameraController.locationID(fromUniqueID: "virtual:OBS") == nil)
        // A leading hex run that's followed by garbage still parses; the bogus
        // location ID then fails to match any IOUSBHostDevice, so virtual cameras
        // degrade gracefully at the IOKit lookup layer rather than here.
    }
}
