#pragma once
#include <stdint.h>
#include <stddef.h>

// IOKit exposes device requests through a C plug-in vtable. The protocol stays in Swift.
typedef struct PulseUSB PulseUSB;
PulseUSB *pulse_usb_connect(const char *mount_path);
void pulse_usb_release(PulseUSB *usb);
int pulse_usb_transfer(PulseUSB *usb, uint8_t type, uint8_t request, uint16_t value, void *data, uint16_t size);
int pulse_raw_size(int fd);
