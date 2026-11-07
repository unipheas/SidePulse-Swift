#pragma once
#include "USBControl.h"
#include <DiskArbitration/DiskArbitration.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/usb/IOUSBLib.h>
#include <sys/stat.h>

/* Explicit OS boundary: tests can model unplug, permission and allocation failures
   without opening a real USB endpoint or mutating the global IOKit implementation. */
typedef struct {
    __typeof__(&DASessionCreate) session_create;
    __typeof__(&DADiskCreateFromVolumePath) disk_create;
    __typeof__(&DADiskCopyIOMedia) media_copy;
    __typeof__(&IOObjectConformsTo) conforms;
    __typeof__(&IORegistryEntryGetParentEntry) parent;
    __typeof__(&IOObjectRelease) release;
    __typeof__(&IORegistryEntryCreateCFProperty) property;
    __typeof__(&IOCreatePlugInInterfaceForService) plugin;
    void *(*allocate)(size_t, size_t);
} PulseUSBOperations;
PulseUSB *pulse_usb_connect_using(const char *mount_path, const PulseUSBOperations *operations);
typedef int (*PulseStat)(int, struct stat *);
typedef int (*PulseIOCtl)(int, unsigned long, void *);
int pulse_raw_size_using(int fd, PulseStat stat_call, PulseIOCtl ioctl_call);
