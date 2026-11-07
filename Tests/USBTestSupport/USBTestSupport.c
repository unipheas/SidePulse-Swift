#include "USBTestSupport.h"
#include "USBOperations.h"
#include <sys/disk.h>
#include <stdlib.h>
#include <string.h>

static int scenario, releases, device_releases, plugin_releases;
static uint16_t dot_id, dot_size;
static IOUSBDeviceInterface182 device;
static IOUSBDeviceInterface182 *device_pointer = &device;
static IOCFPlugInInterface plugin;
static IOCFPlugInInterface *plugin_pointer = &plugin;
static DASessionRef session_create(CFAllocatorRef allocator) {
    return scenario == 1 ? NULL : (DASessionRef)CFStringCreateWithCString(NULL, "session", kCFStringEncodingUTF8);
}
static DADiskRef disk_create(CFAllocatorRef allocator, DASessionRef session, CFURLRef url) {
    return scenario == 2 ? NULL : (DADiskRef)CFStringCreateWithCString(NULL, "disk", kCFStringEncodingUTF8);
}
static io_service_t media_copy(DADiskRef disk) { return scenario == 3 ? 0 : 10; }
static boolean_t conforms(io_object_t object, const io_name_t name) {
    return object == 20 && scenario != 4 && (scenario != 16 || strcmp(name, "IOUSBDevice") == 0);
}
static kern_return_t parent(io_registry_entry_t node, const io_name_t plane, io_registry_entry_t *parent) {
    *parent = node == 10 ? 20 : 0; return KERN_SUCCESS;
}
static kern_return_t release(io_object_t object) { releases++; return KERN_SUCCESS; }
static CFTypeRef property(io_registry_entry_t node, CFStringRef key, CFAllocatorRef allocator, IOOptionBits options) {
    if (scenario == 5) return NULL;
    if (scenario == 6) return CFRetain(CFSTR("not a number"));
    int value = CFEqual(key, CFSTR("idVendor")) ? 0x1a86 : (scenario == 7 ? 0 : 0xfe10);
    return CFNumberCreate(NULL, kCFNumberIntType, &value);
}
static ULONG plugin_release(void *self) { plugin_releases++; return 0; }
static ULONG device_release(void *self) { device_releases++; return 0; }
static HRESULT query(void *self, REFIID iid, LPVOID *result) {
    *result = scenario == 9 ? NULL : &device_pointer; return S_OK;
}
static IOReturn request(void *self, IOUSBDevRequestTO *req) {
    if (scenario >= 13) {
        if (req->wIndex != 0x5350) return kIOReturnBadArgument;
        if (req->bmRequestType == 0x40 && req->bRequest == 0x50) {
            dot_id = req->wValue; dot_size = req->wLength;
            req->wLenDone = req->wLength;
            return scenario == 15 ? kIOReturnError : kIOReturnSuccess;
        }
        if (req->bmRequestType == 0xc0 && req->bRequest == 0x51 && req->wLength == 16) {
            uint8_t status[16] = {'S', 'P', 'C', '2', dot_id & 255, dot_id >> 8, dot_id ? 3 : 0, 0,
                dot_size & 255, dot_size >> 8, dot_size & 255, dot_size >> 8, dot_id ? 1 : 0};
            memcpy(req->pData, status, sizeof(status)); req->wLenDone = 16;
            return scenario == 14 ? kIOReturnError : kIOReturnSuccess;
        }
        return kIOReturnBadArgument;
    }
    if (req->wIndex != 0x5350 || req->bmRequestType != 0xc0 || req->bRequest != 0x51 || req->wValue != 7) return kIOReturnBadArgument;
    memset(req->pData, 0x42, req->wLength);
    req->wLenDone = scenario == 11 ? 0 : req->wLength;
    return scenario == 12 ? kIOReturnError : kIOReturnSuccess;
}
static IOReturn create_plugin(io_service_t service, CFUUIDRef type, CFUUIDRef uuid, IOCFPlugInInterface ***output, SInt32 *score) {
    *output = scenario == 8 ? NULL : &plugin_pointer; return kIOReturnSuccess;
}
static void *allocate(size_t count, size_t size) { return scenario == 10 ? NULL : calloc(count, size); }
PulseUSB *test_dot_connection(int failure) {
    scenario = 13 + failure; dot_id = dot_size = 0; device_releases = 0;
    PulseUSBOperations api = {session_create, disk_create, media_copy, conforms, parent, release, property, create_plugin, allocate};
    memset(&plugin, 0, sizeof(plugin)); memset(&device, 0, sizeof(device));
    plugin.QueryInterface = query; plugin.Release = plugin_release;
    device.Release = device_release; device.DeviceRequestTO = request;
    return pulse_usb_connect_using("/tmp", &api);
}
int test_usb_release_count(void) { return device_releases; }
int test_usb_adapter(void) {
    PulseUSBOperations api = {session_create, disk_create, media_copy, conforms, parent, release, property, create_plugin, allocate};
    memset(&plugin, 0, sizeof(plugin)); memset(&device, 0, sizeof(device));
    plugin.QueryInterface = query; plugin.Release = plugin_release;
    device.Release = device_release; device.DeviceRequestTO = request;
    for (scenario = 0; scenario <= 12; scenario++) {
        releases = device_releases = plugin_releases = 0;
        PulseUSB *usb = pulse_usb_connect_using("/tmp", &api);
        if (scenario >= 1 && scenario <= 10) {
            if (usb) { pulse_usb_release(usb); return 100 + scenario; }
            if (scenario == 10 && device_releases != 1) return 110;
        } else {
            if (!usb) return 200 + scenario;
            unsigned char bytes[16] = {0};
            int result = pulse_usb_transfer(usb, 0xc0, 0x51, 7, bytes, sizeof(bytes));
            if (result != (scenario == 0) || bytes[0] != 0x42) return 300 + scenario;
            pulse_usb_release(usb);
            if (device_releases != 1 || plugin_releases != 1 || releases != 2) return 400 + scenario;
        }
    }
    // An empty file-system representation cannot form a volume URL.
    scenario = 0;
    PulseUSB *empty = pulse_usb_connect_using("", &api);
    if (empty) { pulse_usb_release(empty); return 500; }
    // Older registry trees expose IOUSBDevice rather than IOUSBHostDevice.
    scenario = 16;
    PulseUSB *legacy = pulse_usb_connect_using("/tmp", &api);
    if (!legacy) return 501;
    pulse_usb_release(legacy);
    pulse_usb_release(NULL);
    return 0;
}
static int fake_stat(int fd, struct stat *info) {
    memset(info, 0, sizeof(*info)); info->st_mode = scenario == 1 ? S_IFREG : scenario == 7 ? S_IFBLK : S_IFCHR;
    return scenario == 0 ? -1 : 0;
}
static int fake_ioctl(int fd, unsigned long request, void *value) {
    if (scenario == 2 || (scenario == 8 && request == DKIOCGETBLOCKCOUNT)) return -1;
    if (request == DKIOCGETBLOCKSIZE) *(uint32_t *)value = scenario == 3 ? 4096 : 512;
    if (request == DKIOCGETBLOCKCOUNT) *(uint64_t *)value = scenario == 4 ? 0 : scenario == 5 ? 10000 : 128;
    return 0;
}
int test_raw_size_adapter(void) {
    for (scenario = 0; scenario <= 8; scenario++) {
        int size = pulse_raw_size_using(0, fake_stat, fake_ioctl);
        if (size != ((scenario == 6 || scenario == 7) ? 65536 : -1)) return scenario + 1;
    }
    return 0;
}
