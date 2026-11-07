#include "USBControl.h"
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

struct PulseUSB { IOUSBDeviceInterface182 **device; };

static int property(io_registry_entry_t node, CFStringRef key) {
    CFTypeRef value = IORegistryEntryCreateCFProperty(node, key, NULL, 0);
    int result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberIntType, &result);
    if (value) CFRelease(value);
    return result;
}

PulseUSB *pulse_usb_connect(const char *mount_path) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)mount_path, strlen(mount_path), true);
    DASessionRef session = DASessionCreate(NULL);
    DADiskRef disk = session && url ? DADiskCreateFromVolumePath(NULL, session, url) : NULL;
    io_registry_entry_t node = disk ? DADiskCopyIOMedia(disk) : 0;
    if (disk) CFRelease(disk);
    if (session) CFRelease(session);
    if (url) CFRelease(url);
    while (node) {
        if (IOObjectConformsTo(node, "IOUSBHostDevice") || IOObjectConformsTo(node, "IOUSBDevice")) break;
        io_registry_entry_t parent = 0;
        IORegistryEntryGetParentEntry(node, kIOServicePlane, &parent);
        IOObjectRelease(node);
        node = parent;
    }
    if (!node) return NULL;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (property(node, CFSTR("idVendor")) == 0x1a86 && property(node, CFSTR("idProduct")) == 0xfe10)
        IOCreatePlugInInterfaceForService(node, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(node);
    if (!plugin) return NULL;
    IOUSBDeviceInterface182 **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (!device) return NULL;
    PulseUSB *usb = calloc(1, sizeof(*usb));
    if (!usb) { (*device)->Release(device); return NULL; }
    usb->device = device;
    return usb;
}
void pulse_usb_release(PulseUSB *usb) {
    if (usb) { (*usb->device)->Release(usb->device); free(usb); }
}
int pulse_usb_transfer(PulseUSB *usb, uint8_t type, uint8_t request, uint16_t value, void *data, uint16_t size) {
    IOUSBDevRequestTO req = { .bmRequestType = type, .bRequest = request, .wValue = value, .wIndex = 0x5350,
        .wLength = size, .pData = data, .noDataTimeout = 1000, .completionTimeout = 1000 };
    IOReturn result = (*usb->device)->DeviceRequestTO(usb->device, &req);
    return result == kIOReturnSuccess && req.wLenDone == size;
}
