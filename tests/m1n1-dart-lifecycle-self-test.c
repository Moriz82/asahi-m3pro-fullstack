/* SPDX-License-Identifier: MIT */
/* Real DART/RTKit source; all page tables, registers and failure signals are fake. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

static void *owned_calloc(size_t n, size_t size);
static void *owned_memalign(size_t alignment, size_t size);
static void owned_free(void *p);
static u32 recorded_read(u64 address);
static void recorded_write(u64 address, u32 value);
static u32 recorded_set(u64 address, u32 value);
static int recorded_poll(u64 address, u32 mask, u32 value, u32 timeout);
static void recorded_barrier(void);
#define calloc owned_calloc
#define memalign owned_memalign
#define free owned_free
#define read32 recorded_read
#define write32 recorded_write
#define set32 recorded_set
#define poll32 recorded_poll
#undef dma_wmb
#define dma_wmb recorded_barrier
#include M1N1_DART_SOURCE
#include M1N1_RTKIT_SOURCE
#undef calloc
#undef memalign
#undef free
#undef read32
#undef write32
#undef set32
#undef poll32
#undef dma_wmb
#undef printf
#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

#define BASE 0x12340000
#define EXPECT_UNCERTAIN (-3)
static u64 pages[32][2048] __attribute__((aligned(16384)));
static bool live_pages[32];
static void *records[64];
static unsigned record_count, allocations, fail_allocation, frees, page_frees, releases, polls;
static unsigned record_allocations, fail_record_allocation, writes;
static bool fail_poll, observed_failed_poll, iova_busy;
static u32 registers[0x2000 / 4];
static enum dart_type_t kind;

static void *owned_calloc(size_t n, size_t size)
{
    if (++record_allocations == fail_record_allocation) return NULL;
    assert(record_count < ARRAY_SIZE(records));
    void *p = calloc(n, size); assert(p); records[record_count++] = p; return p;
}
static void *owned_memalign(size_t alignment, size_t size)
{
    assert(alignment == SZ_16K && size == SZ_16K);
    if (++allocations == fail_allocation) return NULL;
    for (unsigned i = 0; i < ARRAY_SIZE(pages); i++) if (!live_pages[i]) {
        live_pages[i] = true; memset(pages[i], 0, SZ_16K); return pages[i];
    }
    abort();
}
static bool page_live(void *p)
{
    for (unsigned i = 0; i < ARRAY_SIZE(pages); i++) if (p == pages[i]) return live_pages[i];
    return false;
}
bool is_heap(void *p) { return page_live(p); }
static bool record_live(void *p)
{
    for (unsigned i = 0; i < record_count; i++) if (records[i] == p) return true;
    return false;
}
static void owned_free(void *p)
{
    if (!p) return;
    assert(!observed_failed_poll && "memory released after unacknowledged invalidation");
    for (unsigned i = 0; i < ARRAY_SIZE(pages); i++) if (p == pages[i]) {
        assert(live_pages[i]); live_pages[i] = false; frees++; page_frees++; return;
    }
    for (unsigned i = 0; i < record_count; i++) if (records[i] == p) {
        free(p); records[i] = records[--record_count]; frees++; return;
    }
    assert(!"free of unowned or interior pointer");
}
static unsigned register_index(u64 address)
{ assert(address >= BASE && address - BASE < sizeof(registers) && !(address & 3)); return (address - BASE) / 4; }
static u32 recorded_read(u64 address) { return registers[register_index(address)]; }
static void recorded_write(u64 address, u32 value)
{ registers[register_index(address)] = value; writes++; }
static u32 recorded_set(u64 address, u32 value)
{ u32 result = recorded_read(address) | value; recorded_write(address, result); return result; }
static int recorded_poll(u64 address, u32 mask, u32 value, u32 timeout)
{
    assert(address == BASE + (kind == DART_T8110 ? 0x80 : 0x20));
    assert(mask == (kind == DART_T8110 ? 0x80000000U : 4U) && !value && timeout == 100);
    polls++; observed_failed_poll |= fail_poll; return fail_poll ? -1 : 0;
}
static void recorded_barrier(void) {}
int debug_printf(const char *format, ...) { (void)format; return 0; }
u64 iova_alloc(iova_domain_t *d, size_t size)
{ assert(d && !iova_busy && size == SZ_16K); iova_busy = true; return SZ_16K; }
void iova_free(iova_domain_t *d, u64 address, size_t size)
{
    assert(d && iova_busy && address == SZ_16K && size == SZ_16K);
    assert(!observed_failed_poll && "IOVA reused after unacknowledged invalidation");
    releases++; iova_busy = false;
}
bool sart_add_allowed_region(sart_dev_t *s, void *p, size_t size)
{ (void)s; (void)p; (void)size; abort(); }
bool sart_remove_allowed_region(sart_dev_t *s, void *p, size_t size)
{ (void)s; (void)p; (void)size; abort(); }

/* Only fake epoch cleanup: production must retain these allocations on failure. */
static void finish_fake_epoch(void)
{
    while (record_count) free(records[--record_count]);
    memset(live_pages, 0, sizeof(live_pages));
}

int main(int argc, char **argv)
{
    assert(argc == 3);
    kind = !strcmp(argv[1], "t8020") ? DART_T8020 : !strcmp(argv[1], "t6000") ? DART_T6000 : DART_T8110;
    const char *mode = argv[2];
    if (!strncmp(mode, "record-oom-", 11)) {
        fail_record_allocation = strtoul(mode + 11, NULL, 10);
        assert(!dart_init(BASE, 0, false, kind));
        assert(!record_count && !writes && !polls);
        for (unsigned i = 0; i < ARRAY_SIZE(pages); i++) assert(!live_pages[i]);
        return 0;
    }
    if (!strcmp(mode, "init-flush")) {
        fail_poll = true;
        assert(!dart_init(BASE, 0, false, kind));
        assert(record_count && polls && !frees); finish_fake_epoch(); return 0;
    }
    dart_dev_t *d = dart_init(BASE, 0, false, kind); assert(d && polls);
    rtkit_dev_t rtk = {.name = "fake", .dart = d, .dart_iovad = (void *)1};
    if (!strcmp(mode, "map-record-oom")) {
        fail_record_allocation = record_allocations + 1;
        unsigned previous_writes = writes, previous_polls = polls;
        assert(dart_map(d, SZ_16K, (void *)0x80000000, SZ_16K) == -1);
        assert(writes == previous_writes && polls == previous_polls);
        dart_shutdown(d); assert(!record_count); return 0;
    }
    if (!strcmp(mode, "healthy")) {
        struct rtkit_buffer b = {0}; assert(rtkit_alloc_buffer(&rtk, &b, SZ_16K));
        assert(b.owned && b.bfr && iova_busy && dart_translate(d, SZ_16K) == b.bfr);
        assert(rtkit_free_buffer(&rtk, &b) && !b.bfr && !iova_busy && releases == 1);
        dart_shutdown(d); assert(!record_count);
        for (unsigned i = 0; i < ARRAY_SIZE(pages); i++) assert(!live_pages[i]);
        return 0;
    }
    if (!strcmp(mode, "borrowed-heap")) {
        assert(!dart_map(d, SZ_16K, (void *)0x80000000, SZ_16K));
        u64 *root = d->l1[0]; unsigned before = frees;
        dart_dev_t *reader = dart_init(BASE, 0, true, kind); assert(reader && reader != d && reader->l1[0] == root);
        dart_shutdown(reader);
        assert(page_live(root) && record_live(d) && frees == before + 1);
        assert(dart_translate(d, SZ_16K) == (void *)0x80000000);
        dart_shutdown(d); assert(!record_count); return 0;
    }
    if (!strcmp(mode, "map-flush") || !strcmp(mode, "rollback-flush")) {
        uintptr_t iova = SZ_16K; size_t size = SZ_16K;
        if (!strcmp(mode, "rollback-flush")) {
            iova = SZ_32M - SZ_16K; size = 2 * SZ_16K; fail_allocation = allocations + 2;
        }
        fail_poll = true;
        assert(dart_map(d, iova, (void *)0x80000000, size) == EXPECT_UNCERTAIN);
        assert(!page_frees && observed_failed_poll); finish_fake_epoch(); return 0;
    }
    if (!strcmp(mode, "rtkit-map")) {
        struct rtkit_buffer b = {0}; fail_poll = true;
        assert(!rtkit_alloc_buffer(&rtk, &b, SZ_16K));
        assert(b.owned && page_live(b.bfr) && iova_busy && !frees && !releases);
        finish_fake_epoch(); return 0;
    }
    if (!strcmp(mode, "rtkit-unmap")) {
        struct rtkit_buffer b = {0}; assert(rtkit_alloc_buffer(&rtk, &b, SZ_16K));
        fail_poll = true; assert(!rtkit_free_buffer(&rtk, &b));
        assert(b.owned && page_live(b.bfr) && iova_busy && !frees && !releases);
        finish_fake_epoch(); return 0;
    }
    assert(!dart_map(d, SZ_16K, (void *)0x80000000, SZ_16K));
    if (!strcmp(mode, "free-l2")) {
        dart_unmap(d, SZ_16K, SZ_16K); fail_poll = true;
        dart_free_l2(d, 0); assert(record_live(d) && !frees && observed_failed_poll);
    } else {
        assert(!strcmp(mode, "shutdown-flush")); fail_poll = true;
        dart_shutdown(d); assert(record_live(d) && !frees && observed_failed_poll);
    }
    finish_fake_epoch(); return 0;
}
