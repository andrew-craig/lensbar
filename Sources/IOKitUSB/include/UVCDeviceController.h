#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// UVC class-specific request codes (UVC 1.5 Table A-14 / A-15).
typedef NS_ENUM(uint8_t, UVCGetRequest) {
    UVCRequestSetCurrent = 0x01,
    UVCRequestGetCurrent = 0x81,
    UVCRequestGetMin     = 0x82,
    UVCRequestGetMax     = 0x83,
    UVCRequestGetRes     = 0x84,
    UVCRequestGetLen     = 0x85,
    UVCRequestGetInfo    = 0x86,
    UVCRequestGetDefault = 0x87,
};

/// Opens an IOUSBHostDevice user-client (device level, not claiming any interface)
/// and sends UVC class-specific control transfers over EP0.
///
/// UVCAssistant holds exclusive ownership of IOUSBHostInterface nodes (interface 0 and 1),
/// but the IOUSBHostDevice parent node is typically unclaimed, so we can open it
/// and route UVC requests through EP0 without evicting UVCAssistant.
@interface UVCDeviceController : NSObject

@property (readonly) BOOL isOpen;

/// Find the USB device with the given VID/PID and open it at the device level.
/// Returns nil (and sets error) if the device is not found or cannot be opened.
- (nullable instancetype)initWithVendorID:(uint16_t)vendorID
                                productID:(uint16_t)productID
                                    error:(NSError **)error NS_DESIGNATED_INITIALIZER;

- (instancetype)init NS_UNAVAILABLE;

/// Tear down the IOUSBHostDevice user-client.  Called automatically in -dealloc.
- (void)closeDevice;

/// Send a UVC class-specific GET request (direction = device-to-host) on EP0.
/// @param request   UVC request code (UVCRequestGetCurrent, UVCRequestGetMin, etc.)
/// @param unitID    UVC unit/terminal ID (e.g. 3 = Processing Unit)
/// @param selector  Control selector (e.g. 0x01 = Brightness)
/// @param intf      Video Control interface number (0 for OBSBOT)
/// @param length    Expected response length in bytes
/// @param error     On failure, populated with the IOKit error
/// @returns NSData containing the response bytes, or nil on failure
- (nullable NSData *)getRequest:(uint8_t)request
                         unitID:(uint8_t)unitID
                       selector:(uint8_t)selector
                      interface:(uint8_t)intf
                         length:(uint16_t)length
                          error:(NSError **)error;

/// Send a UVC SET_CUR request (direction = host-to-device) on EP0.
/// @param selector  Control selector
/// @param unitID    UVC unit/terminal ID
/// @param intf      Video Control interface number
/// @param data      Value bytes to write
/// @param error     On failure, populated with the IOKit error
/// @returns YES on success
- (BOOL)setCurrent:(uint8_t)selector
            unitID:(uint8_t)unitID
         interface:(uint8_t)intf
              data:(NSData *)data
             error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
