#import "UVCDeviceController.h"
#import <IOUSBHost/IOUSBHost.h>
#import <IOKit/IOKitLib.h>

// bmRequestType byte values for UVC class-specific interface requests.
// Direction | Type=Class | Recipient=Interface
static const uint8_t kUVCBmRequestTypeGet = 0xA1; // device-to-host | class | interface
static const uint8_t kUVCBmRequestTypeSet = 0x21; // host-to-device | class | interface

// bmRequestType for the standard GET_DESCRIPTOR request, recipient=device.
static const uint8_t kStdBmRequestTypeGetDevice = 0x80; // device-to-host | standard | device
static const uint8_t kStdRequestGetDescriptor   = 0x06;
static const uint8_t kDescriptorTypeConfiguration = 0x02;

@implementation UVCDeviceController {
    IOUSBHostDevice *_device;
}

// MARK: - Private: open from io_service_t

- (nullable instancetype)initWithService:(io_service_t)service
                                   error:(NSError **)outError {
    self = [super init];
    if (!self) {
        IOObjectRelease(service);
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

// MARK: - Public initializers

- (nullable instancetype)initWithVendorID:(uint16_t)vendorID
                                productID:(uint16_t)productID
                                    error:(NSError **)outError {
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

    return [self initWithService:service error:outError];
}

- (nullable instancetype)initWithLocationID:(uint32_t)locationID
                                      error:(NSError **)outError {
    // Match against any IOUSBHostDevice with the given locationID. We don't pass
    // VID/PID — the location ID alone uniquely identifies the device on this host
    // for as long as it's plugged into the same port.
    CFMutableDictionaryRef matchingDict = IOServiceMatching("IOUSBHostDevice");
    if (!matchingDict) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:1
                userInfo:@{NSLocalizedDescriptionKey: @"Failed to create IOUSBHostDevice matching dictionary"}];
        }
        return nil;
    }

    // IOKit USB property key for the device's location ID (depth-encoded port path).
    // Stable for as long as the device is plugged into the same port.
    CFDictionarySetValue(matchingDict, CFSTR("locationID"), (__bridge CFNumberRef)@(locationID));

    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict);
    if (service == IO_OBJECT_NULL) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:2
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"USB device with locationID=0x%08X not found", locationID]}];
        }
        return nil;
    }

    return [self initWithService:service error:outError];
}

- (BOOL)isOpen { return _device != nil; }

- (void)closeDevice {
    [_device destroy];
    _device = nil;
}

- (void)dealloc { [self closeDevice]; }

// MARK: - Descriptor read (standard GET_DESCRIPTOR on EP0)

- (nullable NSData *)getConfigurationDescriptorWithError:(NSError **)outError {
    if (!_device) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:3
                userInfo:@{NSLocalizedDescriptionKey: @"Device not open"}];
        }
        return nil;
    }

    // Two-step read: the first 9 bytes are the configuration descriptor header,
    // which carries wTotalLength (bytes 2-3, little-endian). Then re-request the
    // full block, which includes interface and class-specific descriptors.
    NSData *header = [self sendGetDescriptor:kDescriptorTypeConfiguration
                                       index:0
                                      length:9
                                       error:outError];
    if (!header || header.length < 4) {
        if (outError && !*outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:4
                userInfo:@{NSLocalizedDescriptionKey: @"Configuration descriptor header truncated"}];
        }
        return nil;
    }

    const uint8_t *bytes = (const uint8_t *)header.bytes;
    uint16_t totalLength = (uint16_t)bytes[2] | ((uint16_t)bytes[3] << 8);
    if (totalLength < 9) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"UVCDeviceController" code:5
                userInfo:@{NSLocalizedDescriptionKey:
                    [NSString stringWithFormat:@"Configuration descriptor wTotalLength=%u too small", totalLength]}];
        }
        return nil;
    }

    return [self sendGetDescriptor:kDescriptorTypeConfiguration
                             index:0
                            length:totalLength
                             error:outError];
}

- (nullable NSData *)sendGetDescriptor:(uint8_t)descriptorType
                                 index:(uint8_t)descriptorIndex
                                length:(uint16_t)length
                                 error:(NSError **)outError {
    IOUSBDeviceRequest req = {
        .bmRequestType = kStdBmRequestTypeGetDevice,
        .bRequest      = kStdRequestGetDescriptor,
        .wValue        = (uint16_t)((descriptorType << 8) | descriptorIndex),
        .wIndex        = 0,
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

// MARK: - UVC class-specific requests

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
