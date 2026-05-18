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

    @Test("Location ID followed by vendor/serial suffix takes the first 8 digits")
    func truncatesAfterEightDigits() {
        // AVCaptureDevice.uniqueID often appends VID/PID or a serial number after the
        // 32-bit location ID; without truncation the whole hex run would overflow UInt32.
        #expect(CameraController.locationID(fromUniqueID: "0x14200000046d082d") == 0x14200000)
        #expect(CameraController.locationID(fromUniqueID: "14200000046d082d") == 0x14200000)
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
