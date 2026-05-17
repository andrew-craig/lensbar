import Foundation
import Testing
@testable import LensBarCore

@Suite("UVC descriptor parser")
struct UVCDescriptorParserTests {

    // MARK: - Topology extraction

    @Test("OBSBOT-like layout: VC=0, CT=1, PU=3")
    func parsesObsbotLikeTopology() throws {
        let bytes: [UInt8] = [
            // Configuration descriptor (9 bytes): wTotalLength=47
            9, 0x02, 47, 0, 1, 1, 0, 0x80, 50,
            // Interface: bInterfaceNumber=0, class=0x0E Video, subclass=0x01 Control
            9, 0x04, 0, 0, 1, 0x0E, 0x01, 0, 0,
            // CS Input Terminal: bTerminalID=1, wTerminalType=0x0201 (ITT_CAMERA)
            18, 0x24, 0x02, 1, 0x01, 0x02, 0, 0,
            0, 0, 0, 0, 0, 0,
            3, 0, 0, 0,
            // CS Processing Unit: bUnitID=3, bSourceID=1
            11, 0x24, 0x05, 3, 1, 0, 0, 2, 0, 0, 0,
        ]
        let topology = try UVCDescriptorParser.parse(Data(bytes))
        #expect(topology.vcInterface == 0)
        #expect(topology.cameraTerminal == 1)
        #expect(topology.processingUnit == 3)
    }

    @Test("Generic layout with non-zero VC interface and different unit IDs")
    func parsesGenericTopology() throws {
        let bytes: [UInt8] = [
            9, 0x02, 47, 0, 1, 1, 0, 0x80, 50,
            9, 0x04, 2, 0, 1, 0x0E, 0x01, 0, 0,
            18, 0x24, 0x02, 4, 0x01, 0x02, 0, 0,
            0, 0, 0, 0, 0, 0,
            3, 0, 0, 0,
            11, 0x24, 0x05, 5, 4, 0, 0, 2, 0, 0, 0,
        ]
        let topology = try UVCDescriptorParser.parse(Data(bytes))
        #expect(topology.vcInterface == 2)
        #expect(topology.cameraTerminal == 4)
        #expect(topology.processingUnit == 5)
    }

    // MARK: - Edge cases

    @Test("Non-camera input terminal (e.g. composite) is not picked up")
    func ignoresNonCameraInputTerminal() throws {
        let bytes: [UInt8] = [
            9, 0x02, 47, 0, 1, 1, 0, 0x80, 50,
            9, 0x04, 0, 0, 1, 0x0E, 0x01, 0, 0,
            // wTerminalType=0x0203 (composite) — should be ignored, not a camera
            18, 0x24, 0x02, 7, 0x03, 0x02, 0, 0,
            0, 0, 0, 0, 0, 0,
            3, 0, 0, 0,
            11, 0x24, 0x05, 3, 7, 0, 0, 2, 0, 0, 0,
        ]
        let topology = try UVCDescriptorParser.parse(Data(bytes))
        #expect(topology.cameraTerminal == nil)
        #expect(topology.processingUnit == 3)
    }

    @Test("Camera Terminal nil when device exposes only a Processing Unit")
    func cameraTerminalNilWhenMissing() throws {
        let bytes: [UInt8] = [
            9, 0x02, 29, 0, 1, 1, 0, 0x80, 50,
            9, 0x04, 0, 0, 1, 0x0E, 0x01, 0, 0,
            11, 0x24, 0x05, 3, 0, 0, 0, 2, 0, 0, 0,
        ]
        let topology = try UVCDescriptorParser.parse(Data(bytes))
        #expect(topology.vcInterface == 0)
        #expect(topology.cameraTerminal == nil)
        #expect(topology.processingUnit == 3)
    }

    @Test("Class-specific descriptors outside a VC interface are ignored")
    func ignoresCSDescriptorsOutsideVideoControl() throws {
        // Audio interface (class=0x01) appears before the VC interface; any 0x24
        // CS descriptors inside it must not be picked up as UVC units.
        let bytes: [UInt8] = [
            9, 0x02, 56, 0, 2, 1, 0, 0x80, 50,
            9, 0x04, 0, 0, 0, 0x01, 0x01, 0, 0,
            // Fake 0x24 descriptor that LOOKS like a PU but is inside an audio iface.
            11, 0x24, 0x05, 99, 1, 0, 0, 2, 0, 0, 0,
            9, 0x04, 1, 0, 1, 0x0E, 0x01, 0, 0,
            18, 0x24, 0x02, 1, 0x01, 0x02, 0, 0,
            0, 0, 0, 0, 0, 0,
            3, 0, 0, 0,
        ]
        let topology = try UVCDescriptorParser.parse(Data(bytes))
        #expect(topology.vcInterface == 1)
        #expect(topology.cameraTerminal == 1)
        #expect(topology.processingUnit == nil)
    }

    @Test("Throws when no VideoControl interface is present")
    func throwsWhenNoVideoControlInterface() {
        let bytes: [UInt8] = [
            9, 0x02, 18, 0, 1, 1, 0, 0x80, 50,
            9, 0x04, 0, 0, 0, 0x01, 0x01, 0, 0,
        ]
        #expect(throws: UVCDescriptorParser.ParseError.self) {
            try UVCDescriptorParser.parse(Data(bytes))
        }
    }

    @Test("Throws on a truncated configuration descriptor")
    func throwsWhenTruncated() {
        #expect(throws: UVCDescriptorParser.ParseError.self) {
            try UVCDescriptorParser.parse(Data([1, 2, 3]))
        }
    }

    @Test("Malformed bLength=0 doesn't loop forever")
    func bailsOnZeroLengthDescriptor() throws {
        // After the config header, a descriptor reporting bLength=0 must stop the
        // walk (length<2 check). The earlier-recorded VC interface still returns.
        let bytes: [UInt8] = [
            9, 0x02, 20, 0, 1, 1, 0, 0x80, 50,
            9, 0x04, 0, 0, 1, 0x0E, 0x01, 0, 0,
            0, 0x24, 0x02,
        ]
        let topology = try UVCDescriptorParser.parse(Data(bytes))
        #expect(topology.vcInterface == 0)
        #expect(topology.cameraTerminal == nil)
    }
}
