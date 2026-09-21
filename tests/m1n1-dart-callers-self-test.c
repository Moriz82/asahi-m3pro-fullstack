/* SPDX-License-Identifier: MIT */
/* Actual registry, kboot cleanup, and proxy branch bodies with owned fakes. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
typedef uint64_t u64;
typedef int iodev_id_t;
typedef int dwc3_dev_t;
typedef int dart_dev_t;
enum { FIRST_USB_IODEV, USB_IODEV_COUNT = 8, IODEV_USB0 = 4, SPINLOCK_ALIGN = 16,
       USAGE_CONSOLE = 1, USAGE_UARTPROXY = 2, P_DART_SHUTDOWN, P_DART_MAP, P_DART_UNMAP };
struct iodev { const void *ops; void *opaque; unsigned usage, lock; };
static struct iodev *registry[8], iodev_usb_vuart;
static int iodev_usb_ops, devices[8];
static unsigned allocation_calls, live, bringups, releases, shuts, failure_port = 99, checks;
static bool allocation_failure, bringup_failure, orphan;
static void *allocate(size_t alignment, size_t size)
{
    assert(alignment == 16 && size == sizeof(struct iodev)); allocation_calls++;
    if (allocation_failure) return NULL;
    live++; void *p = calloc(1, size); assert(p); return p;
}
static void release(void *p) { if (p) { assert(live); live--; releases++; free(p); } }
static void spin_init(unsigned *lock) { *lock = 0; }
static void *iodev_get_opaque(iodev_id_t id)
{ assert(id >= 4 && id < 12); return registry[id - 4] ? registry[id - 4]->opaque : NULL; }
static void iodev_register_device(iodev_id_t id, struct iodev *dev)
{ assert(!registry[id - 4]); registry[id - 4] = dev; }
static struct iodev *iodev_unregister_device(iodev_id_t id)
{ struct iodev *dev = registry[id - 4]; assert(dev && !devices[id - 4]); registry[id - 4] = NULL; return dev; }
static dwc3_dev_t *usb_iodev_bringup(unsigned port)
{ assert(port < 8); bringups++; if (bringup_failure) return NULL; devices[port] = 1; return &devices[port]; }
static bool usb_dwc3_shutdown(dwc3_dev_t *dev)
{
    unsigned port = dev - devices; assert(port < 8 && *dev && iodev_usb_vuart.opaque != dev);
    assert(registry[port] && registry[port]->opaque == dev); shuts++;
    if (port == failure_port) return false;
    *dev = 0; return true;
}
static bool usb_dwc3_has_faults(void) { return orphan; }
static int diagnostic(const char *format, ...) { (void)format; return 0; }
#define memalign allocate
#define free release
#define printf diagnostic
#include "usb.inc"
#undef free
#undef printf
#undef memalign

static unsigned dart_calls, fail_dart;
static bool dart_shutdown(dart_dev_t *dart)
{ if (!dart) return true; dart_calls++; return *dart != (int)fail_dart; }
static bool dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
{ assert(dart && iova == 0x10000 && size == 0x4000); return !fail_dart; }
static int dart_map(dart_dev_t *dart, uintptr_t iova, void *p, size_t size)
{ assert(dart && iova == 0x10000 && p && size == 0x4000); return fail_dart ? -3 : 0; }
static int cleanup(dart_dev_t *dart_dcp, dart_dev_t *dart_disp, dart_dev_t *dart_piodma, int ret)
{
#include "kboot.inc"
/* Included actual tail closes this function. */
struct packet { u64 args[4], retval; };
static void dispatch(unsigned operation, struct packet *request, struct packet *reply)
{
    switch (operation) {
#include "proxy.inc"
        default: abort();
    }
}

int main(void)
{
    allocation_failure = true; usb_iodev_init(); assert(!live && !bringups); checks++;
    allocation_failure = false; bringup_failure = true; usb_iodev_init();
    assert(!live && bringups == 8 && releases == 8); checks++;
    bringup_failure = false; usb_iodev_init(); assert(live == 8 && bringups == 16); checks++;
    unsigned before = allocation_calls; usb_iodev_init();
    assert(allocation_calls == before && bringups == 16 && live == 8); checks++;
    usb_iodev_vuart_setup(IODEV_USB0 + 3); assert(iodev_usb_vuart.opaque == &devices[3]);
    failure_port = 3;
    assert(!usb_iodev_shutdown() && live == 5 && registry[3] && devices[3]);
    assert(!iodev_usb_vuart.opaque && shuts == 4); checks++;
    failure_port = 99;
    assert(usb_iodev_shutdown() && !live && shuts == 9); checks++;
    assert(usb_iodev_shutdown()); orphan = true; assert(!usb_iodev_shutdown()); checks++;
    int darts[] = {1, 2, 3};
    for (unsigned failure = 0; failure < 4; failure++) {
        fail_dart = failure; dart_calls = 0;
        assert(cleanup(&darts[0], &darts[1], &darts[2], 0) == (failure ? -1 : 0));
        assert(dart_calls == 3); checks++;
    }
    fail_dart = 0; dart_calls = 0;
    assert(cleanup(NULL, NULL, NULL, -7) == -7 && !dart_calls); checks++;
    for (unsigned failure = 0; failure < 2; failure++) {
        fail_dart = failure;
        struct packet request = {.args = {(u64)&darts[0], 0x10000, 0x4000, 0}};
        struct packet reply = {.retval = 99};
        dispatch(P_DART_SHUTDOWN, &request, &reply); assert(reply.retval == !failure); checks++;
        reply.retval = 99;
        dispatch(P_DART_UNMAP, &request, &reply); assert(reply.retval == !failure); checks++;
        request.args[2] = (u64)devices; request.args[3] = 0x4000;
        dispatch(P_DART_MAP, &request, &reply); assert((int64_t)reply.retval == (failure ? -3 : 0)); checks++;
    }
    printf("PASS: USB registry/kboot/proxy callers (%u cases)\n", checks);
}
