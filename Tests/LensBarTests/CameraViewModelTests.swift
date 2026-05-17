import Testing
@testable import LensBarCore

@Suite("CameraViewModel static invariants")
@MainActor
struct CameraViewModelTests {

    @Test("Slider list excludes 1-byte mode controls (powerLineFrequency, hueAuto, whiteBalanceTempAuto)")
    func sliderControlsExcludeModeBytes() {
        let sliders = Set(CameraViewModel.sliderControls)
        let modeBytes: Set<PUControl> = [.powerLineFrequency, .hueAuto, .whiteBalanceTempAuto]
        #expect(sliders.isDisjoint(with: modeBytes))
    }

    @Test("All slider controls are 2-byte analog PU controls")
    func sliderControlsAreAllTwoByte() {
        for ctrl in CameraViewModel.sliderControls {
            #expect(ctrl.dataLength == 2, "Expected 2-byte data length for \(ctrl)")
        }
    }

    @Test("Slider list contains no duplicates")
    func sliderControlsAreUnique() {
        let sliders = CameraViewModel.sliderControls
        #expect(Set(sliders).count == sliders.count)
    }
}
