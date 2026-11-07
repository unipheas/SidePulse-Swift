#include "USBOperations.h"
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <stdlib.h>
#include <string.h>

struct PulseUSB { IOUSBDeviceInterface182 **device; };

static int property(const PulseUSBOperations *api, io_registry_entry_t node, CFStringRef key) {
    CFTypeRef value = api->property(node, key, NULL, 0);
    int result = -1;
    if (value && CFGetTypeID(value) == CFNumberGetTypeID())
        CFNumberGetValue(value, kCFNumberIntType, &result);
    if (value) CFRelease(value);
    return result;
}

static const PulseUSBOperations system_operations = {
    DASessionCreate, DADiskCreateFromVolumePath, DADiskCopyIOMedia,
    IOObjectConformsTo, IORegistryEntryGetParentEntry, IOObjectRelease,
    IORegistryEntryCreateCFProperty, IOCreatePlugInInterfaceForService, calloc
};
PulseUSB *pulse_usb_connect(const char *mount_path) {
    return pulse_usb_connect_using(mount_path, &system_operations);
}
PulseUSB *pulse_usb_connect_using(const char *mount_path, const PulseUSBOperations *api) {
    CFURLRef url = CFURLCreateFromFileSystemRepresentation(NULL, (const UInt8 *)mount_path, strlen(mount_path), true);
    DASessionRef session = api->session_create(NULL);
    DADiskRef disk = session && url ? api->disk_create(NULL, session, url) : NULL;
    io_registry_entry_t node = disk ? api->media_copy(disk) : 0;
    if (disk) CFRelease(disk);
    if (session) CFRelease(session);
    if (url) CFRelease(url);
    while (node) {
        if (api->conforms(node, "IOUSBHostDevice") || api->conforms(node, "IOUSBDevice")) break;
        io_registry_entry_t parent = 0;
        api->parent(node, kIOServicePlane, &parent);
        api->release(node);
        node = parent;
    }
    if (!node) return NULL;
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    if (property(api, node, CFSTR("idVendor")) == 0x1a86 && property(api, node, CFSTR("idProduct")) == 0xfe10)
        api->plugin(node, kIOUSBDeviceUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    api->release(node);
    if (!plugin) return NULL;
    IOUSBDeviceInterface182 **device = NULL;
    (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID182), (LPVOID *)&device);
    (*plugin)->Release(plugin);
    if (!device) return NULL;
    PulseUSB *usb = api->allocate(1, sizeof(*usb));
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

#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
static int system_ioctl(int fd, unsigned long request, void *value) { return ioctl(fd, request, value); }
int pulse_raw_size(int fd) { return pulse_raw_size_using(fd, fstat, system_ioctl); }
int pulse_raw_size_using(int fd, PulseStat stat_call, PulseIOCtl ioctl_call) {
    struct stat info;
    uint32_t block = 0;
    uint64_t count = 0;
    if (stat_call(fd, &info) || !(S_ISBLK(info.st_mode) || S_ISCHR(info.st_mode))) return -1;
    if (ioctl_call(fd, DKIOCGETBLOCKSIZE, &block) || ioctl_call(fd, DKIOCGETBLOCKCOUNT, &count)) return -1;
    if (block != 512 || count == 0 || count > 300000 / block) return -1;
    return (int)(count * block);
}
