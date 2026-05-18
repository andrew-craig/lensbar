import Foundation

/// Unit IDs discovered from a USB Video Class configuration descriptor.
/// Any of the unit IDs may be nil if the device doesn't expose that unit —
/// callers should hide UI for controls that depend on a missing unit.
struct UVCTopology: Equatable, Sendable {
    let vcInterface: UInt8
    let cameraTerminal: UInt8?
    let processingUnit: UInt8?
}

/// Walks a USB configuration descriptor and extracts the UVC topology
/// (VideoControl interface number + Camera Terminal and Processing Unit IDs).
///
/// Descriptor layout per USB 2.0 §9.5 and UVC 1.5 §3.7:
/// - Configuration descriptor: [bLength, bDescriptorType, wTotalLength_lo, wTotalLength_hi, ...]
/// - Each subsequent descriptor is a TLV with bLength at byte 0 and bDescriptorType at byte 1.
/// - Interface descriptors (type 0x04) have bInterfaceClass at byte 5 and bInterfaceSubClass at byte 6.
///   The VideoControl interface is class=0x0E subclass=0x01.
/// - Class-specific VC descriptors have bDescriptorType=0x24 and a bDescriptorSubtype at byte 2:
///   * 0x02 INPUT_TERMINAL: bTerminalID at byte 3, wTerminalType at bytes 4-5.
///     wTerminalType=0x0201 identifies a Camera Terminal (ITT_CAMERA).
///   * 0x05 PROCESSING_UNIT: bUnitID at byte 3.
enum UVCDescriptorParser {

    enum ParseError: Error, LocalizedError {
        case truncated
        case noVideoControlInterface

        var errorDescription: String? {
            switch self {
            case .truncated:                return "USB configuration descriptor is truncated"
            case .noVideoControlInterface:  return "Device has no UVC VideoControl interface"
            }
        }
    }

    // Standard USB descriptor types.
    private static let descriptorInterface: UInt8 = 0x04
    private static let descriptorCSInterface: UInt8 = 0x24

    // USB class codes for UVC.
    private static let videoClass: UInt8 = 0x0E
    private static let videoSubclassControl: UInt8 = 0x01

    // VC class-specific subtypes (UVC 1.5 §A.5).
    private static let vcInputTerminal: UInt8 = 0x02
    private static let vcProcessingUnit: UInt8 = 0x05

    // wTerminalType for ITT_CAMERA (UVC 1.5 §B.2).
    private static let inputTerminalCamera: UInt16 = 0x0201

    static func parse(_ data: Data) throws -> UVCTopology {
        let bytes = Array(data)
        guard bytes.count >= 9 else { throw ParseError.truncated }

        var vcInterface: UInt8? = nil
        var cameraTerminal: UInt8? = nil
        var processingUnit: UInt8? = nil
        var inVideoControl = false

        var offset = Int(bytes[0])  // Skip the configuration descriptor header (bLength bytes).
        while offset < bytes.count {
            let length = Int(bytes[offset])
            guard length >= 2, offset + length <= bytes.count else {
                // Malformed descriptor — stop parsing rather than over-reading.
                break
            }
            let type = bytes[offset + 1]

            if type == descriptorInterface, length >= 9 {
                // Interface descriptor: bInterfaceClass=byte5, bInterfaceSubClass=byte6.
                let cls = bytes[offset + 5]
                let sub = bytes[offset + 6]
                if cls == videoClass && sub == videoSubclassControl {
                    inVideoControl = true
                    if vcInterface == nil {
                        vcInterface = bytes[offset + 2]  // bInterfaceNumber
                    }
                } else {
                    inVideoControl = false
                }
            } else if inVideoControl && type == descriptorCSInterface, length >= 3 {
                let subtype = bytes[offset + 2]
                switch subtype {
                case vcInputTerminal where length >= 6:
                    let terminalType = UInt16(bytes[offset + 4]) | (UInt16(bytes[offset + 5]) << 8)
                    if terminalType == inputTerminalCamera, cameraTerminal == nil {
                        cameraTerminal = bytes[offset + 3]  // bTerminalID
                    }
                case vcProcessingUnit where length >= 4:
                    if processingUnit == nil {
                        processingUnit = bytes[offset + 3]  // bUnitID
                    }
                default:
                    break
                }
            }

            offset += length
        }

        guard let iface = vcInterface else {
            throw ParseError.noVideoControlInterface
        }
        return UVCTopology(
            vcInterface: iface,
            cameraTerminal: cameraTerminal,
            processingUnit: processingUnit
        )
    }
}
