import Foundation
import Testing
import VirtualCameraKit

@Suite("VirtualCameraFormat")
struct VirtualCameraFormatTests {

    @Test("Encodes as WxH@num/den fourcc")
    func encode() {
        let f = VirtualCameraFormat(width: 1280, height: 720, fpsNumerator: 25)
        #expect(f.encoded == "1280x720@25/1 420v")
    }

    @Test("Round-trips through the string form",
          arguments: ["1280x720@25/1 420v", "1920x1080@30000/1001 420v", "640x480@15/1 420v", "3840x2160@60/1 420v"])
    func roundTrip(s: String) throws {
        let f = try #require(VirtualCameraFormat(encoded: s))
        #expect(f.encoded == s)
        #expect(VirtualCameraFormat(encoded: f.encoded) == f)
    }

    @Test("Rejects malformed strings",
          arguments: ["", "1280x720", "1280x720@25 420v", "1280x720@25/1", "1280-720@25/1 420v",
                      "axb@25/1 420v", "1280x720@25/1 420v extra", "1280x720@25/1 42"])
    func malformed(s: String) {
        #expect(VirtualCameraFormat(encoded: s) == nil)
    }

    @Test("Rejects out-of-range or unsupported values",
          arguments: ["0x720@25/1 420v", "1281x720@25/1 420v", "1280x721@25/1 420v", "9000x720@25/1 420v",
                      "1280x720@0/1 420v", "1280x720@25/0 420v", "1280x720@500/1 420v", "1280x720@-25/1 420v",
                      "1280x720@25/1 BGRA"])
    func invalid(s: String) {
        #expect(VirtualCameraFormat(encoded: s) == nil)
    }

    @Test("Whole frame rates map to n/1")
    func wholeRates() throws {
        for fps in [1.0, 5, 15, 24, 25, 30, 50, 60, 120] {
            let f = try #require(VirtualCameraFormat(width: 1280, height: 720, fps: fps))
            #expect(f.fpsNumerator == Int32(fps))
            #expect(f.fpsDenominator == 1)
        }
    }

    @Test("Near-whole rates from AVFrameRateRange round")
    func nearWhole() throws {
        let f = try #require(VirtualCameraFormat(width: 1280, height: 720, fps: 25.000_01))
        #expect(f.fpsNumerator == 25 && f.fpsDenominator == 1)
    }

    @Test("NTSC rates map to n*1000/1001", arguments: [(29.97, 30000), (59.94, 60000), (23.976, 24000)])
    func ntsc(fps: Double, num: Int32) throws {
        let f = try #require(VirtualCameraFormat(width: 1920, height: 1080, fps: fps))
        #expect(f.fpsNumerator == num)
        #expect(f.fpsDenominator == 1001)
        #expect(abs(f.framesPerSecond - fps) < 0.001)
    }

    @Test("Frame duration is den/num seconds")
    func frameDuration() throws {
        let f = try #require(VirtualCameraFormat(encoded: "1920x1080@30000/1001 420v"))
        #expect(f.frameDuration.value == 1001)
        #expect(f.frameDuration.timescale == 30000)
    }

    @Test("Settings init rejects bad input")
    func badSettings() {
        #expect(VirtualCameraFormat(width: 1280, height: 720, fps: 0) == nil)
        #expect(VirtualCameraFormat(width: 1280, height: 720, fps: .nan) == nil)
        #expect(VirtualCameraFormat(width: 1280, height: 720, fps: .infinity) == nil)
        #expect(VirtualCameraFormat(width: 0, height: 720, fps: 25) == nil)
        #expect(VirtualCameraFormat(width: Int(Int32.max) + 1, height: 720, fps: 25) == nil)
    }

    @Test("Default is valid")
    func defaultValid() {
        #expect(VirtualCameraFormat.default.isValid)
    }
}

@Suite("Custom CMIO properties")
struct VirtualCameraPropertyTests {

    @Test("Selectors are the big-endian four-character codes")
    func selectors() {
        #expect(VirtualCameraProperty.clientCount.selector == 0x6C62_6363) // 'lbcc'
        #expect(VirtualCameraProperty.format.selector == 0x6C62_666D) // 'lbfm'
    }

    @Test("Extension property names use the 4cc_<code>_glob_0000 form")
    func names() {
        #expect(VirtualCameraProperty.clientCount.extensionPropertyName == "4cc_lbcc_glob_0000")
        #expect(VirtualCameraProperty.format.extensionPropertyName == "4cc_lbfm_glob_0000")
    }

    @Test("Client count codec")
    func clientCount() {
        #expect(ClientCountCodec.encode(3) == "3")
        #expect(ClientCountCodec.encode(-1) == "0")
        #expect(ClientCountCodec.decode("0") == 0)
        #expect(ClientCountCodec.decode(" 2 ") == 2)
        #expect(ClientCountCodec.decode("-1") == nil)
        #expect(ClientCountCodec.decode("x") == nil)
    }

    @Test("Identity UIDs are distinct valid UUIDs")
    func uids() {
        let uids = [VirtualCameraIdentity.deviceUID, VirtualCameraIdentity.initialSourceStreamUID,
                    VirtualCameraIdentity.initialSinkStreamUID]
        #expect(uids.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(Set(uids).count == 3)
    }
}
