import Foundation

enum UVCError: Error, LocalizedError {
    case deviceNotFound
    case deviceOpenFailed(String)
    case transferFailed(String)
    case invalidValue(String)
    case sessionFailed(String)
    case deviceInUse

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:        return "No UVC camera found"
        case .deviceOpenFailed(let m): return "Failed to open USB device: \(m)"
        case .transferFailed(let m):   return "USB control transfer failed: \(m)"
        case .invalidValue(let m):     return "Invalid value: \(m)"
        case .sessionFailed(let m):    return "AVFoundation session error: \(m)"
        case .deviceInUse:             return "Camera is in use by another application"
        }
    }
}

// MARK: - UVC request codes (UVC 1.5 §A.14 / §A.15)

enum UVCRequest: UInt8 {
    case setCurrent  = 0x01
    case getCurrent  = 0x81
    case getMin      = 0x82
    case getMax      = 0x83
    case getRes      = 0x84
    case getLen      = 0x85
    case getInfo     = 0x86
    case getDefault  = 0x87
}

// MARK: - Processing Unit control selectors (UVC 1.5 Table A-8)

enum PUControl: UInt8, CaseIterable {
    case brightness                = 0x01
    case contrast                  = 0x02
    case hue                       = 0x03
    case saturation                = 0x04
    case sharpness                 = 0x05
    case gamma                     = 0x06
    case whiteBalanceTemperature   = 0x07
    case backlightCompensation     = 0x09
    case gain                      = 0x0A
    case powerLineFrequency        = 0x0B
    case hueAuto                   = 0x0C
    case whiteBalanceTempAuto      = 0x0D

    // Data length in bytes for the control value
    var dataLength: Int {
        switch self {
        case .powerLineFrequency, .hueAuto, .whiteBalanceTempAuto: return 1
        default: return 2
        }
    }

    var displayName: String {
        switch self {
        case .brightness:              return "Brightness"
        case .contrast:                return "Contrast"
        case .hue:                     return "Hue"
        case .saturation:              return "Saturation"
        case .sharpness:               return "Sharpness"
        case .gamma:                   return "Gamma"
        case .whiteBalanceTemperature: return "White Balance Temperature"
        case .backlightCompensation:   return "Backlight Compensation"
        case .gain:                    return "Gain"
        case .powerLineFrequency:      return "Power Line Frequency"
        case .hueAuto:                 return "Hue Auto"
        case .whiteBalanceTempAuto:    return "White Balance Temp Auto"
        }
    }
}

// MARK: - Camera Terminal control selectors (UVC 1.5 Table A-4)

enum CTControl: UInt8, CaseIterable {
    case scanningMode         = 0x01
    case autoExposureMode     = 0x02
    case autoExposurePriority = 0x03
    case exposureTimeAbsolute = 0x04
    case focusAbsolute        = 0x06
    case focusAuto            = 0x08
    case zoomAbsolute         = 0x0B
    case panTiltAbsolute      = 0x0D

    var dataLength: Int {
        switch self {
        case .scanningMode, .autoExposureMode, .autoExposurePriority, .focusAuto: return 1
        case .focusAbsolute, .zoomAbsolute: return 2
        case .exposureTimeAbsolute: return 4
        case .panTiltAbsolute: return 8
        }
    }

    var displayName: String {
        switch self {
        case .scanningMode:         return "Scanning Mode"
        case .autoExposureMode:     return "Auto Exposure Mode"
        case .autoExposurePriority: return "Auto Exposure Priority"
        case .exposureTimeAbsolute: return "Exposure Time"
        case .focusAbsolute:        return "Focus Absolute"
        case .focusAuto:            return "Focus Auto"
        case .zoomAbsolute:         return "Zoom Absolute"
        case .panTiltAbsolute:      return "PanTilt Absolute"
        }
    }
}

// MARK: - Auto Exposure Mode bitmap (UVC 1.5 §4.2.2.1.2)

/// CT_AE_MODE_CONTROL is a 1-byte bitmap; SET_CUR accepts a single bit
/// indicating the desired mode. Only Manual and Auto are exposed here —
/// shutter/aperture priority aren't typically supported on UVC webcams.
enum AEMode: UInt8 {
    case manual = 0x01  // manual exposure time, manual iris
    case auto   = 0x02  // auto exposure time, auto iris
}
