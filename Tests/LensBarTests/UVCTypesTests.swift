import Testing
@testable import LensBarCore

@Suite("UVC type definitions")
struct UVCTypesTests {

    // MARK: - Device identity

    @Test func obsbotIdentity() {
        #expect(OBSBOT.vendorID == 0x3564)
        #expect(OBSBOT.productID == 0xFEFE)
        #expect(OBSBOT.name == "OBSBOT Meet SE")
        #expect(OBSBOT.UnitID.cameraTerminal == 1)
        #expect(OBSBOT.UnitID.extensionUnit == 2)
        #expect(OBSBOT.UnitID.processingUnit == 3)
        #expect(OBSBOT.UnitID.videoControlInterface == 0)
        #expect(OBSBOT.ExtensionUnit.numControls == 7)
    }

    // MARK: - UVC request codes (UVC 1.5 §A.14/§A.15)

    @Test func uvcRequestRawValues() {
        #expect(UVCRequest.setCurrent.rawValue == 0x01)
        #expect(UVCRequest.getCurrent.rawValue == 0x81)
        #expect(UVCRequest.getMin.rawValue     == 0x82)
        #expect(UVCRequest.getMax.rawValue     == 0x83)
        #expect(UVCRequest.getRes.rawValue     == 0x84)
        #expect(UVCRequest.getLen.rawValue     == 0x85)
        #expect(UVCRequest.getInfo.rawValue    == 0x86)
        #expect(UVCRequest.getDefault.rawValue == 0x87)
    }

    // MARK: - Auto-exposure mode bitmap (UVC 1.5 §4.2.2.1.2)

    @Test func aeModeBitmap() {
        #expect(AEMode.manual.rawValue == 0x01)
        #expect(AEMode.auto.rawValue   == 0x02)
    }

    // MARK: - Processing Unit selectors (UVC 1.5 Table A-8)

    @Test func puControlSelectors() {
        #expect(PUControl.brightness.rawValue              == 0x01)
        #expect(PUControl.contrast.rawValue                == 0x02)
        #expect(PUControl.hue.rawValue                     == 0x03)
        #expect(PUControl.saturation.rawValue              == 0x04)
        #expect(PUControl.sharpness.rawValue               == 0x05)
        #expect(PUControl.gamma.rawValue                   == 0x06)
        #expect(PUControl.whiteBalanceTemperature.rawValue == 0x07)
        #expect(PUControl.backlightCompensation.rawValue   == 0x09)
        #expect(PUControl.gain.rawValue                    == 0x0A)
        #expect(PUControl.powerLineFrequency.rawValue      == 0x0B)
        #expect(PUControl.hueAuto.rawValue                 == 0x0C)
        #expect(PUControl.whiteBalanceTempAuto.rawValue    == 0x0D)
    }

    @Test("PU data lengths: 1 byte for mode bytes, 2 bytes for analog values",
          arguments: [
            (PUControl.brightness,              2),
            (PUControl.contrast,                2),
            (PUControl.hue,                     2),
            (PUControl.saturation,              2),
            (PUControl.sharpness,               2),
            (PUControl.gamma,                   2),
            (PUControl.whiteBalanceTemperature, 2),
            (PUControl.backlightCompensation,   2),
            (PUControl.gain,                    2),
            (PUControl.powerLineFrequency,      1),
            (PUControl.hueAuto,                 1),
            (PUControl.whiteBalanceTempAuto,    1),
          ])
    func puDataLengths(control: PUControl, expected: Int) {
        #expect(control.dataLength == expected)
    }

    @Test func puDisplayNamesAreUnique() {
        let names = PUControl.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test func puAllCasesCoverage() {
        // Guard against accidental removal of a selector.
        #expect(PUControl.allCases.count == 12)
    }

    // MARK: - Camera Terminal selectors (UVC 1.5 Table A-4)

    @Test func ctControlSelectors() {
        #expect(CTControl.scanningMode.rawValue         == 0x01)
        #expect(CTControl.autoExposureMode.rawValue     == 0x02)
        #expect(CTControl.autoExposurePriority.rawValue == 0x03)
        #expect(CTControl.exposureTimeAbsolute.rawValue == 0x04)
        #expect(CTControl.focusAbsolute.rawValue        == 0x06)
        #expect(CTControl.focusAuto.rawValue            == 0x08)
        #expect(CTControl.zoomAbsolute.rawValue         == 0x0B)
        #expect(CTControl.panTiltAbsolute.rawValue      == 0x0D)
    }

    @Test("CT data lengths per UVC spec",
          arguments: [
            (CTControl.scanningMode,         1),
            (CTControl.autoExposureMode,     1),
            (CTControl.autoExposurePriority, 1),
            (CTControl.focusAuto,            1),
            (CTControl.focusAbsolute,        2),
            (CTControl.zoomAbsolute,         2),
            (CTControl.exposureTimeAbsolute, 4),
            (CTControl.panTiltAbsolute,      8),
          ])
    func ctDataLengths(control: CTControl, expected: Int) {
        #expect(control.dataLength == expected)
    }

    @Test func ctDisplayNamesAreUnique() {
        let names = CTControl.allCases.map(\.displayName)
        #expect(Set(names).count == names.count)
        #expect(names.allSatisfy { !$0.isEmpty })
    }

    @Test func ctAllCasesCoverage() {
        #expect(CTControl.allCases.count == 8)
    }
}
