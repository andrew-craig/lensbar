import Foundation
import IOKitUSB
import os

private let log = Logger(subsystem: "com.lensbar", category: "uvc")

/// Controls UVC camera parameters through the IOUSBHostDevice node (not through
/// any interface).  Because EP0 control transfers are at device level, this path
/// works even though UVCAssistant holds exclusive ownership of IOUSBHostInterface@0.
///
/// Failure to open the device (e.g. if macOS ever restricts device-level access)
/// is surfaced as a throwing init; callers can fall back gracefully.
///
/// `@unchecked Sendable`: all stored properties are immutable lets; the underlying
/// `IOUSBHostDevice` (held by `UVCDeviceController`) accepts `sendDeviceRequest`
/// from any thread. This lets `CameraController` build the controller in a
/// detached task off the main actor.
final class IOKitUVCController: @unchecked Sendable {

    private let controller: UVCDeviceController
    private let topology: UVCTopology
    private let supportedPU: Set<PUControl>
    private let supportedCT: Set<CTControl>

    init(locationID: UInt32, topology: UVCTopology) throws {
        do {
            controller = try UVCDeviceController(locationID: locationID)
        } catch {
            throw UVCError.deviceOpenFailed(error.localizedDescription)
        }
        self.topology = topology
        self.supportedPU = Self.probePU(controller: controller, topology: topology)
        self.supportedCT = Self.probeCT(controller: controller, topology: topology)
        let puNames = self.supportedPU.map { $0.displayName }.sorted().joined(separator: ", ")
        let ctNames = self.supportedCT.map { $0.displayName }.sorted().joined(separator: ", ")
        log.info("probe summary supportedPU=[\(puNames, privacy: .public)] supportedCT=[\(ctNames, privacy: .public)]")
    }

    deinit { controller.closeDevice() }

    /// Read the device's configuration descriptor and parse the UVC topology
    /// (VC interface number + Camera Terminal / Processing Unit IDs). Used by
    /// `CameraController` to discover unit IDs at runtime before constructing
    /// an `IOKitUVCController`.
    static func readTopology(locationID: UInt32) throws -> UVCTopology {
        let dev: UVCDeviceController
        do {
            dev = try UVCDeviceController(locationID: locationID)
        } catch {
            throw UVCError.deviceOpenFailed(error.localizedDescription)
        }
        defer { dev.closeDevice() }
        let data: Data
        do {
            data = try dev.getConfigurationDescriptor()
        } catch {
            throw UVCError.transferFailed("GET_DESCRIPTOR(configuration): \(error.localizedDescription)")
        }
        return try UVCDescriptorParser.parse(data)
    }

    // MARK: - Processing Unit

    struct PURange {
        let current: Int16
        let min: Int16
        let max: Int16
        let defaultValue: Int16
        let resolution: Int16
    }

    func isSupported(_ control: PUControl) -> Bool { supportedPU.contains(control) }
    func isSupported(_ control: CTControl) -> Bool { supportedCT.contains(control) }

    func getPU(_ control: PUControl, request: UVCRequest = .getCurrent) -> Int16? {
        guard let unitID = topology.processingUnit else { return nil }
        return readInt16(
            request: request.rawValue,
            unitID: unitID,
            selector: control.rawValue,
            length: control.dataLength
        )
    }

    func setPU(_ control: PUControl, value: Int16) throws {
        guard let unitID = topology.processingUnit else {
            throw UVCError.invalidValue("Processing Unit not present on this device")
        }
        var v = value
        let data = Data(bytes: &v, count: control.dataLength)
        try writeControl(
            selector: control.rawValue,
            unitID: unitID,
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
        guard let unitID = topology.cameraTerminal else { return nil }
        guard let data = readRaw(
            request: request.rawValue,
            unitID: unitID,
            selector: control.rawValue,
            length: control.dataLength
        ) else { return nil }
        return Self.decodeLEInt(data, length: control.dataLength)
    }

    func setCT(_ control: CTControl, value: Int) throws {
        guard let unitID = topology.cameraTerminal else {
            throw UVCError.invalidValue("Camera Terminal not present on this device")
        }
        let data = Self.encodeLE(value: value, length: control.dataLength)
        try writeControl(
            selector: control.rawValue,
            unitID: unitID,
            data: data
        )
    }

    // MARK: - Capability probing

    private static func probePU(controller: UVCDeviceController, topology: UVCTopology) -> Set<PUControl> {
        probe(controller: controller, unitID: topology.processingUnit, interface: topology.vcInterface)
    }

    private static func probeCT(controller: UVCDeviceController, topology: UVCTopology) -> Set<CTControl> {
        probe(controller: controller, unitID: topology.cameraTerminal, interface: topology.vcInterface)
    }

    private static func probe<Control: ProbeableControl>(
        controller: UVCDeviceController,
        unitID: UInt8?,
        interface: UInt8
    ) -> Set<Control> {
        guard let unitID else { return [] }
        return Set(Control.allCases.filter {
            probeControl($0, controller: controller, unitID: unitID, interface: interface)
        })
    }

    private static func probeControl<Control: ProbeableControl>(
        _ ctrl: Control,
        controller: UVCDeviceController,
        unitID: UInt8,
        interface: UInt8
    ) -> Bool {
        let (supported, detail) = probeOutcome(
            controller: controller,
            unitID: unitID,
            selector: ctrl.rawValue,
            interface: interface,
            dataLength: ctrl.dataLength
        )
        let hex = String(format: "%02X", ctrl.rawValue)
        let verdict = supported ? "supported" : "unsupported"
        log.debug("""
            probe \(ctrl.displayName, privacy: .public) unit=\(unitID) selector=0x\(hex, privacy: .public): \
            \(detail, privacy: .public) -> \(verdict, privacy: .public)
            """)
        return supported
    }

    /// GET_INFO returns a 1-byte bitmap; bit 0 = GET supported, bit 1 = SET supported.
    /// UVC 1.5 mandates GET_INFO on every implemented control, but real-world
    /// firmware is uneven — plenty of cameras stall or return zero for GET_INFO
    /// even when GET_CUR works fine. So we treat a non-zero GET_INFO as
    /// authoritative and, if that fails, fall back to a GET_CUR probe: if the
    /// device returns any value for the control's selector, the control exists.
    ///
    /// Returns the verdict and a short description of how it was reached, for the log.
    private static func probeOutcome(
        controller: UVCDeviceController,
        unitID: UInt8,
        selector: UInt8,
        interface: UInt8,
        dataLength: Int
    ) -> (supported: Bool, detail: String) {
        let infoDetail: String
        do {
            let info = try controller.getRequest(
                UVCRequest.getInfo.rawValue,
                unitID: unitID,
                selector: selector,
                interface: interface,
                length: 1
            )
            if let first = info.first, first != 0 {
                return (true, "GET_INFO=0x\(String(format: "%02X", first))")
            }
            infoDetail = "GET_INFO returned 0"
        } catch {
            infoDetail = "GET_INFO failed (\(error.localizedDescription))"
        }
        do {
            let data = try controller.getRequest(
                UVCRequest.getCurrent.rawValue,
                unitID: unitID,
                selector: selector,
                interface: interface,
                length: UInt16(dataLength)
            )
            // A truthful GET_CUR for a real control returns dataLength bytes. An
            // empty response means the device acked the request but provided no
            // value — treat that as "control isn't really there" so we don't
            // surface a slider that can't read or write a value.
            guard !data.isEmpty else {
                return (false, "\(infoDetail), GET_CUR empty")
            }
            return (true, "\(infoDetail), GET_CUR ok (\(data.count) bytes)")
        } catch {
            return (false, "\(infoDetail), GET_CUR failed (\(error.localizedDescription))")
        }
    }

    // MARK: - Private helpers

    private func readRaw(request: UInt8, unitID: UInt8, selector: UInt8, length: Int) -> Data? {
        return try? controller.getRequest(
            request,
            unitID: unitID,
            selector: selector,
            interface: topology.vcInterface,
            length: UInt16(length)
        )
    }

    private func readInt16(request: UInt8, unitID: UInt8, selector: UInt8, length: Int) -> Int16? {
        guard let data = readRaw(request: request, unitID: unitID, selector: selector, length: length)
        else { return nil }
        return Self.decodeInt16(data, length: length)
    }

    // MARK: - Byte helpers (internal for testing)

    /// Decode a little-endian byte buffer of up to 8 bytes as an Int.
    /// Returns 0 for empty data; truncates if `length` exceeds `data.count`.
    static func decodeLEInt(_ data: Data, length: Int) -> Int {
        var result = 0
        for i in 0..<min(length, data.count) { result |= Int(data[i]) << (i * 8) }
        return result
    }

    /// Decode a 1- or 2-byte signed value. 1-byte values are sign-extended.
    /// Returns nil if the buffer is too short.
    static func decodeInt16(_ data: Data, length: Int) -> Int16? {
        if length == 1 {
            return data.isEmpty ? nil : Int16(Int8(bitPattern: data[0]))
        }
        guard data.count >= 2 else { return nil }
        return Int16(bitPattern: UInt16(data[0]) | (UInt16(data[1]) << 8))
    }

    /// Encode an Int as a little-endian byte buffer of the given length.
    static func encodeLE(value: Int, length: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: length)
        for i in 0..<length { bytes[i] = UInt8((value >> (i * 8)) & 0xFF) }
        return Data(bytes)
    }

    private func writeControl(selector: UInt8, unitID: UInt8, data: Data) throws {
        try controller.setCurrent(
            selector,
            unitID: unitID,
            interface: topology.vcInterface,
            data: data
        )
    }
}

/// The shape `IOKitUVCController.probe` needs from `PUControl` and `CTControl`.
private protocol ProbeableControl: RawRepresentable<UInt8>, CaseIterable, Hashable {
    var dataLength: Int { get }
    var displayName: String { get }
}

extension PUControl: ProbeableControl {}
extension CTControl: ProbeableControl {}
