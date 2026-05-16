#import "UVCDeviceController.h"
#import <IOUSBHost/IOUSBHost.h>
#import <IOKit/IOKitLib.h>

// bmRequestType byte values for UVC class-specific interface requests.
// Direction | Type=Class | Recipient=Interface
static const uint8_t kUVCBmRequestTypeGet = 0xA1; // device-to-host | class | interface
static const uint8_t kUVCBmRequestTypeSet = 0x21; // host-to-device | class | interface

@implementation UVCDeviceController {
    IOUSBHostDevice *_device;
}

- (nullable instancetype)initWithVendorID:(uint16_t)vendorID
                                productID:(uint16_t)productID
                                    error:(NSError **)outError {
    self = [super init];
    if (!self) return nil;

    // Build IOKit matching dictionary for IOUSBHostDevice with VID/PID.
    CFMutableDictionaryRef matchingDict = [IOUSBHostDevice
        createMatchingDictionaryWithVendorID:@(vendorID)
                                   productID:@(productID)
                                   bcdDevice:nil
                                 deviceClass:nil
                              deviceSubclass:nil
                              deviceProtocol:nil
                                       speed:nil
                                productIDArray:nil];
    if (!matchingDict) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Failed to create USB matching dictionary"}];
        }
        return nil;
    }

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict);
    // matchingDict is consumed (released) by IOServiceGetMatchingService.
    if (service == IO_OBJECT_NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"USB device VID=0x%04X PID=0x%04X not found", vendorID, productID]}];
        }
        return nil;
    }

    NSError *initError = nil;
    // Open the device node — does NOT claim any interface, so UVCAssistant's
    // ownership of IOUSBHostInterface@0 is undisturbed.
    _device = [[IOUSBHostDevice alloc] initWithIOService:service
                                                   queue:nil
                                                   error:&initError
                                         interestHandler:nil];
    IOObjectRelease(service);

    if (!_device) {
        if (outError) *outError = initError;
        return nil;
    }

    return self;
}

- (BOOL)isOpen { return _device != nil; }

- (void)closeDevice {
    [_device destroy];
    _device = nil;
}

- (void)dealloc { [self closeDevice]; }

- (nullable NSData *)getRequest:(uint8_t)request
                         unitID:(uint8_t)unitID
                       selector:(uint8_t)selector
                      interface:(uint8_t)intf
                         length:(uint16_t)length
                          error:(NSError **)outError {
    if (!_device) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Device not open"}];
        }
        return nil;
    }

    // wIndex for UVC: high byte = unit/terminal ID, low byte = interface number.
    // wValue for UVC: high byte = control selector, low byte = 0.
    IOUSBDeviceRequest req = {
        .bmRequestType = kUVCBmRequestTypeGet,
        .bRequest      = request,
        .wValue        = (uint16_t)(selector << 8),
        .wIndex        = (uint16_t)((unitID << 8) | intf),
        .wLength       = length,
    };

    NSMutableData *data = [[NSMutableData alloc] initWithLength:length];
    NSUInteger bytesTransferred = 0;

    BOOL ok = [_device sendDeviceRequest:req
                                    data:data
                        bytesTransferred:&bytesTransferred
                                   error:outError];
    if (!ok) return nil;

    return [data subdataWithRange:NSMakeRange(0, MIN(bytesTransferred, (NSUInteger)length))];
}

- (BOOL)setCurrent:(uint8_t)selector
            unitID:(uint8_t)unitID
         interface:(uint8_t)intf
              data:(NSData *)data
             error:(NSError **)outError {
    if (!_device) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Device not open"}];
        }
        return NO;
    }

    IOUSBDeviceRequest req = {
        .bmRequestType = kUVCBmRequestTypeSet,
        .bRequest      = UVCRequestSetCurrent,
        .wValue        = (uint16_t)(selector << 8),
        .wIndex        = (uint16_t)((unitID << 8) | intf),
        .wLength       = (uint16_t)data.length,
    };

    NSMutableData *mutableData = [data mutableCopy];
    NSUInteger bytesTransferred = 0;

    return [_device sendDeviceRequest:req
                                 data:mutableData
                     bytesTransferred:&bytesTransferred
                                error:outError];
}

@end
