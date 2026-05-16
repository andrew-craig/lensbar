import Foundation
import IOKitUSB

/// Controls UVC camera parameters through the IOUSBHostDevice node (not through
/// any interface).  Because EP0 control transfers are at device level, this path
/// works even though UVCAssistant holds exclusive ownership of IOUSBHostInterface@0.
///
/// Failure to open the device (e.g. if macOS ever restricts device-level access)
/// is surfaced as a throwing init; callers can fall back gracefully.
final class IOKitUVCController {

    private let controller: UVCDeviceController

    init() throws {
        // ObjC designated initializers with (NSError**) become throwing in Swift.
        // The error: label is dropped; the method throws on failure.
        do {
            controller = try UVCDeviceController(vendorID: OBSBOT.vendorID, productID: OBSBOT.productID)
        } catch {
            throw UVCError.deviceOpenFailed(error.localizedDescription)
        }
    }

    deinit { controller.closeDevice() }

    // MARK: - Processing Unit

    struct PURange {
        let current: Int16
        let min: Int16
        let max: Int16
        let defaultValue: Int16
        let resolution: Int16
    }

    func getPU(_ control: PUControl, request: UVCRequest = .getCurrent) -> Int16? {
        readInt16(
            request: request.rawValue,
            unitID: OBSBOT.UnitID.processingUnit,
            selector: control.rawValue,
            length: control.dataLength
        )
    }

    func setPU(_ control: PUControl, value: Int16) throws {
        var v = value
        let data = Data(bytes: &v, count: control.dataLength)
        try writeControl(
            selector: control.rawValue,
            unitID: OBSBOT.UnitID.processingUnit,
            data: data
        )
    }

    func getPURange(_ control: PUControl) -> PURange? {
        guard let cur = getPU(control, request: .getCurrent),
              let min = getPU(control, request: .getMin),
              let max = getPU(control, request: .getMax),
              let def = getPU(control, request: .getDefault),
              let res = getPU(control, request: .getRes)
        else { return nil }
        return PURange(current: cur, min: min, max: max, defaultValue: def, resolution: res)
    }

    // MARK: - Camera Terminal

    func getCT(_ control: CTControl, request: UVCRequest = .getCurrent) -> Int? {
        guard let data = readRaw(
            request: request.rawValue,
            unitID: OBSBOT.UnitID.cameraTerminal,
            selector: control.rawValue,
            length: control.dataLength
        ) else { return nil }
        return leInt(data, length: control.dataLength)
    }

    func setCT(_ control: CTControl, value: Int) throws {
        var bytes = [UInt8](repeating: 0, count: control.dataLength)
        for i in 0..<control.dataLength { bytes[i] = UInt8((value >> (i * 8)) & 0xFF) }
        try writeControl(
            selector: control.rawValue,
            unitID: OBSBOT.UnitID.cameraTerminal,
            data: Data(bytes)
        )
    }

    // MARK: - Extension Unit (OBSBOT proprietary)

    /// Raw get on the proprietary extension unit (unitID=2).
    /// Control semantics are undocumented; returns raw bytes.
    func getXU(selector: UInt8, request: UVCRequest = .getCurrent, length: Int) -> Data? {
        readRaw(
            request: request.rawValue,
            unitID: OBSBOT.UnitID.extensionUnit,
            selector: selector,
            length: length
        )
    }

    func setXU(selector: UInt8, data: Data) throws {
        try writeControl(
            selector: selector,
            unitID: OBSBOT.UnitID.extensionUnit,
            data: data
        )
    }

    // MARK: - Private helpers

    private func readRaw(request: UInt8, unitID: UInt8, selector: UInt8, length: Int) -> Data? {
        // ObjC method with (NSError**) becomes throwing in Swift; error: label is dropped.
        return try? controller.getRequest(
            request,
            unitID: unitID,
            selector: selector,
            interface: OBSBOT.UnitID.videoControlInterface,
            length: UInt16(length)
        )
    }

    private func readInt16(request: UInt8, unitID: UInt8, selector: UInt8, length: Int) -> Int16? {
        guard let data = readRaw(request: request, unitID: unitID, selector: selector, length: length)
        else { return nil }
        if length == 1 {
            return data.isEmpty ? nil : Int16(Int8(bitPattern: data[0]))
        }
        guard data.count >= 2 else { return nil }
        return Int16(bitPattern: UInt16(data[0]) | (UInt16(data[1]) << 8))
    }

    private func leInt(_ data: Data, length: Int) -> Int {
        var result = 0
        for i in 0..<min(length, data.count) { result |= Int(data[i]) << (i * 8) }
        return result
    }

    private func writeControl(selector: UInt8, unitID: UInt8, data: Data) throws {
        // ObjC BOOL+NSError** method becomes throwing Void in Swift.
        try controller.setCurrent(
            selector,
            unitID: unitID,
            interface: OBSBOT.UnitID.videoControlInterface,
            data: data
        )
    }
}
