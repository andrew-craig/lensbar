import Foundation
import Testing
@testable import LensBarCore

@Suite("Own virtual camera filtering")
struct VirtualCameraIdentityTests {

    @Test("Device UID is a valid UUID")
    func uidIsUUID() {
        #expect(UUID(uuidString: VirtualCameraIdentity.deviceUID) != nil)
    }

    @Test("Matches the device UID case-insensitively")
    func matchesOwnUID() {
        #expect(VirtualCameraIdentity.isOwnDevice(uniqueID: VirtualCameraIdentity.deviceUID))
        #expect(VirtualCameraIdentity.isOwnDevice(uniqueID: VirtualCameraIdentity.deviceUID.lowercased()))
    }

    @Test("Does not match physical or other virtual cameras")
    func ignoresOthers() {
        #expect(!VirtualCameraIdentity.isOwnDevice(uniqueID: "0x1120000003e7f63d"))
        #expect(!VirtualCameraIdentity.isOwnDevice(uniqueID: UUID().uuidString))
        #expect(!VirtualCameraIdentity.isOwnDevice(uniqueID: ""))
    }

    @Test("Filter removes only LensBar Camera and keeps order")
    func filterList() {
        let devices = [
            ("0x1120000003e7f63d", "OBSBOT Meet SE"),
            (VirtualCameraIdentity.deviceUID, VirtualCameraIdentity.deviceName),
            ("47B4B64B70674B9CAD2BAE273A71F4B5", "FaceTime HD Camera"),
        ]
        let kept = VirtualCameraIdentity.excludingOwnDevice(devices) { $0.0 }
        #expect(kept.map(\.1) == ["OBSBOT Meet SE", "FaceTime HD Camera"])
    }
}
