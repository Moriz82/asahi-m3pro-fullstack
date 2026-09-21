/* SPDX-License-Identifier: MIT */
/* Actual complete DWC3 and ringbuffer source. All MMIO and DART operations are fake. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"
static void *test_calloc(size_t n, size_t size);
static void *test_memalign(size_t alignment, size_t size);
static void test_free(void *p);
static u32 test_read32(u64 address);
static void test_write32(u64 address, u32 value);
static int test_poll32(u64 address, u32 mask, u32 value, u32 timeout);
static void test_debug(const char *format, ...);
#define calloc test_calloc
#define memalign test_memalign
#define free test_free
#define read32 test_read32
#define write32 test_write32
#define set32(a, b) test_write32((a), test_read32(a) | (b))
#define clear32(a, b) test_write32((a), test_read32(a) & ~(b))
#define mask32(a, m, b) test_write32((a), (test_read32(a) & ~(m)) | (b))
#define poll32 test_poll32
#define debug_printf test_debug
#include M1N1_USB_SOURCE
#include M1N1_RING_SOURCE
#undef calloc
#undef memalign
#undef free
#undef read32
#undef write32
#undef set32
#undef clear32
#undef mask32
#undef poll32
#undef debug_printf
#undef printf
#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

#define BASE 0x12340000
static u32 registers[0x10000 / 4];
static void *allocations[32];
static unsigned live, alloc_count, fail_alloc, frees, maps, unmaps, dart_frees, fail_unmap;
static unsigned fail_map_at;
static int map_result;
static bool unsafe, dart_faulted, fail_dart_free, fail_halt, fail_reset, fail_end;
static bool callback_requested, callback_active, callback_seen;
static dwc3_dev_t *callback_dev;
static int fake_dart;
#define DART ((dart_dev_t *)&fake_dart)

static bool shutdown_checked(dwc3_dev_t *dev)
{
#ifdef USB_LIFECYCLE
    return usb_dwc3_shutdown(dev);
#else
    usb_dwc3_shutdown(dev);
    return true;
#endif
}
static void *test_memalign(size_t alignment, size_t size)
{
    if (++alloc_count == fail_alloc) return NULL;
    void *p = NULL;
    assert(!posix_memalign(&p, alignment, size));
    assert(p && live < ARRAY_SIZE(allocations));
    memset(p, 0, size); allocations[live++] = p; return p;
}
static void *test_calloc(size_t n, size_t size) { return test_memalign(16, n * size); }
static void test_free(void *p)
{
    if (!p) return;
    assert(!unsafe && !callback_active && "USB memory freed without quiescence or active-frame exit");
    unsigned i = 0;
    while (i < live && allocations[i] != p) i++;
    assert(i < live && "unowned or duplicate free");
    allocations[i] = allocations[--live]; frees++; free(p);
}
static unsigned index_of(u64 address)
{
    assert(address >= BASE && address - BASE < sizeof(registers) && !(address & 3));
    return (address - BASE) / 4;
}
static u32 test_read32(u64 address) { return registers[index_of(address)]; }
static void test_write32(u64 address, u32 value) { registers[index_of(address)] = value; }
static int test_poll32(u64 address, u32 mask, u32 value, u32 timeout)
{
    assert(timeout == 1000);
    bool failed = (fail_halt && address == BASE + DWC3_DSTS) ||
                  (fail_reset && address == BASE + DWC3_DCTL) ||
                  (fail_end && address == BASE + DWC3_DEPCMD(1));
    unsafe |= failed;
    if (failed) return -1;
    test_write32(address, (test_read32(address) & ~mask) | value);
    return 0;
}
static void test_debug(const char *format, ...)
{
    (void)format;
    if (!callback_requested) return;
    callback_requested = false;
    callback_active = callback_seen = true;
#ifdef USB_LIFECYCLE
    assert(callback_dev->active_calls || callback_dev->shutting_down);
    usb_dwc3_handle_events(callback_dev); /* Recursive dispatch must be suppressed. */
#endif
    assert(!shutdown_checked(callback_dev));
    assert(!frees && live == 13);
    callback_active = false;
}
void udelay(unsigned int delay) { (void)delay; }
void *adt;
const void *adt_getprop(const void *tree, int node, const char *name, u32 *size)
{ (void)tree; (void)node; (void)name; (void)size; return NULL; }
int dart_map(dart_dev_t *dart, uintptr_t iova, void *buffer, size_t size)
{
    assert(dart == DART && iova && buffer && size);
    maps++;
    if (maps != fail_map_at) return 0;
    if (map_result == -3) unsafe = dart_faulted = true;
    return map_result;
}
#ifdef DART_LIFECYCLE
bool dart_is_faulted(const dart_dev_t *dart) { return !dart || dart_faulted; }
bool dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
#else
void dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
#endif
{
    assert(dart == DART && iova && size);
    unmaps++;
    if (unmaps == fail_unmap) unsafe = dart_faulted = true;
#ifdef DART_LIFECYCLE
    return !dart_faulted;
#endif
}
#ifdef DART_LIFECYCLE
bool dart_shutdown(dart_dev_t *dart)
#else
void dart_shutdown(dart_dev_t *dart)
#endif
{
    assert(dart == DART);
    if (fail_dart_free) unsafe = dart_faulted = true;
    if (!dart_faulted) dart_frees++;
#ifdef DART_LIFECYCLE
    return !dart_faulted;
#endif
}

static dwc3_dev_t *healthy_init(void)
{
    test_write32(BASE + DWC3_GSNPSID, 0x33310000);
    dwc3_dev_t *dev = usb_dwc3_init(BASE, DART);
    assert(dev && live == 13 && maps == 4 && !frees && !dart_frees);
#ifdef USB_LIFECYCLE
    assert(owned_devices == dev && usb_dwc3_owns_regs(BASE) && !usb_dwc3_has_faults());
#endif
    dev->pipe[0].ready = true;
    return dev;
}
static void end_fake_epoch(void)
{
    /* Test-owned arena only. This is not production recovery or forced cleanup. */
#ifdef USB_LIFECYCLE
    owned_devices = NULL;
#endif
    while (live) free(allocations[--live]);
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    const char *mode = argv[1];
    test_write32(BASE + DWC3_GSNPSID, 0x33310000);
    if (!strcmp(mode, "invalid-core") || !strcmp(mode, "constructor-oom") ||
        !strncmp(mode, "allocation-", 11) || !strncmp(mode, "map-safe-", 9) ||
        !strcmp(mode, "map-uncertain")) {
        if (!strcmp(mode, "invalid-core")) test_write32(BASE + DWC3_GSNPSID, 0);
        if (!strcmp(mode, "constructor-oom")) fail_alloc = 1;
        if (!strncmp(mode, "allocation-", 11)) fail_alloc = strtoul(mode + 11, NULL, 10);
        if (!strncmp(mode, "map-safe-", 9)) {
            fail_map_at = strtoul(mode + 9, NULL, 10); map_result = -1;
        }
        if (!strcmp(mode, "map-uncertain")) { fail_map_at = 2; map_result = -3; }
        assert(!usb_dwc3_init(BASE, DART));
        if (unsafe) {
            assert(live == 5 && !frees && !dart_frees);
#ifdef USB_LIFECYCLE
            assert(owned_devices && usb_dwc3_has_faults() && usb_dwc3_owns_regs(BASE));
            assert(!usb_dwc3_init(BASE, DART) && live == 5);
#endif
        } else {
            assert(!live && dart_frees == 1);
        }
        end_fake_epoch(); return 0;
    }

    dwc3_dev_t *dev = healthy_init();
    if (!strcmp(mode, "healthy")) {
        assert(shutdown_checked(dev));
        assert(!live && frees == 13 && unmaps == 4 && dart_frees == 1);
        return 0;
    }
#ifdef USB_LIFECYCLE
    if (!strcmp(mode, "duplicate")) {
        assert(!usb_dwc3_init(BASE, DART) && !frees && !dart_frees && live == 13);
        assert(!usb_dwc3_init(BASE + 0x10000, DART) && !frees && !dart_frees && live == 13);
        assert(shutdown_checked(dev)); return 0;
    }
    if (!strcmp(mode, "invalid-pipe")) {
        u8 byte = 1;
        assert(!usb_dwc3_getbyte(dev, CDC_ACM_PIPE_MAX));
        usb_dwc3_putbyte(dev, CDC_ACM_PIPE_MAX, byte);
        assert(!usb_dwc3_can_read(dev, CDC_ACM_PIPE_MAX));
        assert(!usb_dwc3_can_write(dev, CDC_ACM_PIPE_MAX));
        assert(!usb_dwc3_queue(dev, CDC_ACM_PIPE_MAX, &byte, 1));
        assert(!usb_dwc3_read(dev, CDC_ACM_PIPE_MAX, &byte, 1));
        assert(!usb_dwc3_write(dev, CDC_ACM_PIPE_MAX, &byte, 1));
        usb_dwc3_flush(dev, CDC_ACM_PIPE_MAX);
        assert(shutdown_checked(dev)); return 0;
    }
#endif
    if (!strncmp(mode, "callback-", 9)) {
        const char *operation = mode + 9;
        callback_requested = true; callback_dev = dev;
        union dwc3_event *event = dev->evtbuffer;
        *event = (union dwc3_event){0};
        event->type.is_devspec = 1; event->devt.type = DWC3_DEVT_DISCONN;
        test_write32(BASE + DWC3_GEVNTCOUNT(0), sizeof(*event));
        u8 byte = 0;
        if (!strcmp(operation, "put") || !strcmp(operation, "queue") ||
            !strcmp(operation, "write") || !strcmp(operation, "flush"))
            dev->pipe[0].device2host->write = dev->pipe[0].device2host->len - 1;
        if (!strcmp(operation, "events")) usb_dwc3_handle_events(dev);
        else if (!strcmp(operation, "get")) usb_dwc3_getbyte(dev, 0);
        else if (!strcmp(operation, "put")) usb_dwc3_putbyte(dev, 0, byte);
        else if (!strcmp(operation, "read")) usb_dwc3_read(dev, 0, &byte, 1);
        else if (!strcmp(operation, "write")) usb_dwc3_write(dev, 0, &byte, 1);
        else if (!strcmp(operation, "queue")) usb_dwc3_queue(dev, 0, &byte, 1);
        else if (!strcmp(operation, "flush")) usb_dwc3_flush(dev, 0);
        else abort();
        assert(callback_seen && !frees && !dart_frees && live == 13);
#ifdef USB_LIFECYCLE
        assert(!dev->active_calls && !dev->handling_events && dev->stopping);
#endif
        assert(shutdown_checked(dev));
        assert(!live); return 0;
    }

    if (!strcmp(mode, "halt")) fail_halt = true;
    else if (!strcmp(mode, "shutdown-reentry")) {
        fail_halt = callback_requested = true; callback_dev = dev;
    }
    else if (!strcmp(mode, "reset")) fail_reset = true;
    else if (!strcmp(mode, "end-transfer")) {
        fail_end = true; dev->endpoints[1].xfer_in_progress = true;
    } else if (!strncmp(mode, "unmap-", 6)) fail_unmap = strtoul(mode + 6, NULL, 10);
    else if (!strcmp(mode, "dart-shutdown")) fail_dart_free = true;
    else abort();
    assert(!shutdown_checked(dev));
    assert(unsafe && live == 13 && !frees && !dart_frees);
#ifdef USB_LIFECYCLE
    if (!strcmp(mode, "shutdown-reentry")) assert(callback_seen && !dev->shutting_down);
    assert(owned_devices == dev && usb_dwc3_has_faults());
    unsigned previous_unmaps = unmaps;
    assert(!shutdown_checked(dev) && unmaps == previous_unmaps && live == 13);
#endif
    end_fake_epoch(); return 0;
}
