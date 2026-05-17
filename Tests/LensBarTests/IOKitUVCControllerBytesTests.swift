import Foundation
import Testing
@testable import LensBar

@Suite("IOKitUVCController byte helpers")
struct IOKitUVCControllerBytesTests {

    // MARK: - decodeLEInt (little-endian unsigned-ish decode used by getCT)

    @Test func decodeLEInt_zero() {
        #expect(IOKitUVCController.decodeLEInt(Data([0, 0, 0, 0]), length: 4) == 0)
    }

    @Test func decodeLEInt_singleByte() {
        #expect(IOKitUVCController.decodeLEInt(Data([0x7F]), length: 1) == 0x7F)
        // 0xFF is decoded as unsigned 255 by this helper (used for CT values where
        // the spec interprets the field per-control; signedness is handled upstream).
        #expect(IOKitUVCController.decodeLEInt(Data([0xFF]), length: 1) == 0xFF)
    }

    @Test func decodeLEInt_twoByteLittleEndian() {
        // 0x1234 little-endian = [0x34, 0x12]
        #expect(IOKitUVCController.decodeLEInt(Data([0x34, 0x12]), length: 2) == 0x1234)
    }

    @Test func decodeLEInt_fourByteExposureTime() {
        // 10000 = 1s in UVC 100µs units = 0x00002710
        #expect(IOKitUVCController.decodeLEInt(Data([0x10, 0x27, 0x00, 0x00]), length: 4) == 10_000)
    }

    @Test func decodeLEInt_truncatesWhenLengthExceedsBuffer() {
        // Decoder reads min(length, data.count) bytes — extra length is silently ignored
        #expect(IOKitUVCController.decodeLEInt(Data([0x01, 0x02]), length: 4) == 0x0201)
    }

    @Test func decodeLEInt_emptyData() {
        #expect(IOKitUVCController.decodeLEInt(Data(), length: 2) == 0)
    }

    // MARK: - decodeInt16 (signed decode used by getPU)

    @Test func decodeInt16_positiveTwoByte() {
        // +100 little-endian = [0x64, 0x00]
        #expect(IOKitUVCController.decodeInt16(Data([0x64, 0x00]), length: 2) == 100)
    }

    @Test func decodeInt16_negativeTwoByte() {
        // -1 little-endian = [0xFF, 0xFF]
        #expect(IOKitUVCController.decodeInt16(Data([0xFF, 0xFF]), length: 2) == -1)
        // -100 = 0xFF9C
        #expect(IOKitUVCController.decodeInt16(Data([0x9C, 0xFF]), length: 2) == -100)
    }

    @Test func decodeInt16_singleByteIsSignExtended() {
        // 0xFF as 1-byte signed is -1, not 255 — this distinguishes Int16 decode
        // from the unsigned decodeLEInt path.
        #expect(IOKitUVCController.decodeInt16(Data([0xFF]), length: 1) == -1)
        #expect(IOKitUVCController.decodeInt16(Data([0x7F]), length: 1) == 127)
        #expect(IOKitUVCController.decodeInt16(Data([0x80]), length: 1) == -128)
        #expect(IOKitUVCController.decodeInt16(Data([0x00]), length: 1) == 0)
    }

    @Test func decodeInt16_returnsNilWhenBufferTooShort() {
        #expect(IOKitUVCController.decodeInt16(Data(), length: 1) == nil)
        #expect(IOKitUVCController.decodeInt16(Data([0x01]), length: 2) == nil)
    }

    // MARK: - encodeLE (used by setCT)

    @Test func encodeLE_singleByte() {
        #expect(IOKitUVCController.encodeLE(value: 0, length: 1)    == Data([0x00]))
        #expect(IOKitUVCController.encodeLE(value: 0x7F, length: 1) == Data([0x7F]))
        #expect(IOKitUVCController.encodeLE(value: 0xFF, length: 1) == Data([0xFF]))
    }

    @Test func encodeLE_twoByteLittleEndian() {
        #expect(IOKitUVCController.encodeLE(value: 0x1234, length: 2) == Data([0x34, 0x12]))
        #expect(IOKitUVCController.encodeLE(value: 256, length: 2)    == Data([0x00, 0x01]))
    }

    @Test func encodeLE_fourByteExposureTime() {
        // 1s exposure = 10000 (100µs units) = 0x00002710
        #expect(IOKitUVCController.encodeLE(value: 10_000, length: 4) == Data([0x10, 0x27, 0x00, 0x00]))
        // 0.1ms = 1 unit
        #expect(IOKitUVCController.encodeLE(value: 1, length: 4)      == Data([0x01, 0x00, 0x00, 0x00]))
    }

    @Test func encodeLE_eightBytePanTilt() {
        // pan = 0x12345678, tilt = 0x7ABCDEF0 packed as two LE int32s.
        // The helper treats the whole 64-bit value as one LE quantity, so encode
        // the full Int and verify byte order matches expected wire format.
        // Top byte kept <0x80 to fit in signed Int64.
        let value: Int = 0x7ABCDEF012345678
        let data = IOKitUVCController.encodeLE(value: value, length: 8)
        #expect(data == Data([0x78, 0x56, 0x34, 0x12, 0xF0, 0xDE, 0xBC, 0x7A]))
    }

    @Test func encodeLE_truncatesHighBytes() {
        // value = 0x1FF, length = 1 → only low byte 0xFF makes it onto the wire
        #expect(IOKitUVCController.encodeLE(value: 0x1FF, length: 1) == Data([0xFF]))
    }

    // MARK: - Round-trip

    @Test("encode then decode round-trips for representative CT values",
          arguments: [
            (1, 1),
            (0x7F, 1),
            (0xFF, 1),
            (0, 2),
            (12345, 2),
            (0xFFFF, 2),
            (10_000, 4),
            (0x12345678, 4),
          ])
    func encodeDecodeRoundTrip(value: Int, length: Int) {
        let encoded = IOKitUVCController.encodeLE(value: value, length: length)
        #expect(encoded.count == length)
        #expect(IOKitUVCController.decodeLEInt(encoded, length: length) == value)
    }
}
