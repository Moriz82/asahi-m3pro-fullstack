/* SPDX-License-Identifier: MIT */
/* Actual dart.c, with recorded MMIO calls and process-owned page tables.
 * No dart_init, hardware register, real device or firmware is executed. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "utils.h"

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled in the offline container"
#endif
#ifndef M1N1_DART_SOURCE
#error "Define M1N1_DART_SOURCE as an absolute dart.c path"
#endif

static unsigned event_count, diagnostics, expected_sid, cases;
static int poll_result;
static const u64 fake_base = 0x12340000;

static void recorded_barrier(void)
{
    assert(event_count++ == 0);
}

static void recorded_write32(u64 address, u32 value)
{
    assert(event_count++ == 1);
    assert(address == fake_base + 0x80);
    assert(value == (0x100U | expected_sid));
}

static int recorded_poll32(u64 address, u32 mask, u32 target, u32 timeout)
{
    assert(event_count++ == 2);
    assert(address == fake_base + 0x80);
    assert(mask == 0x80000000U && target == 0 && timeout == 100);
    return poll_result;
}

#undef dma_wmb
#define dma_wmb recorded_barrier
#define write32 recorded_write32
#define poll32 recorded_poll32
#include M1N1_DART_SOURCE
#undef dma_wmb
#undef write32
#undef poll32
#undef printf

int debug_printf(const char *format, ...)
{
    assert(strcmp(format, "dart: DART_T8110_TLB_CMD_BUSY did not clear.\n") == 0);
    diagnostics++;
    return 0;
}

/* Non-PIE keeps these owned arrays representable by all tested PTE formats. */
static u64 l1[2048] __attribute__((aligned(16384)));
static u64 l2[2048] __attribute__((aligned(16384)));
static u64 target_page[2048] __attribute__((aligned(16384)));
static u64 saved_l1[2048], saved_l2[2048];

static u64 pte(const struct dart_params *params, void *address)
{
    u64 value = FIELD_PREP(params->offset_mask, (u64)address >> DART_PTE_OFFSET_SHIFT);
    assert((FIELD_GET(params->offset_mask, value) << DART_PTE_OFFSET_SHIFT) == (u64)address);
    return value | DART_PTE_VALID;
}

static void search_case(const struct dart_params *params, unsigned ttbr, unsigned a, unsigned b)
{
    dart_dev_t dart = {.params = params};
    memset(l1, 0, sizeof(l1));
    memset(l2, 0, sizeof(l2));
    dart.l1[ttbr] = l1;
    l1[a] = pte(params, l2);
    l2[b] = pte(params, target_page);
    memcpy(saved_l1, l1, sizeof(l1));
    memcpy(saved_l2, l2, sizeof(l2));
    u64 expected = ((u64)ttbr << 36) | ((u64)a << 25) | ((u64)b << 14);
    assert(dart_search(&dart, target_page) == expected);
    assert(memcmp(l1, saved_l1, sizeof(l1)) == 0);
    assert(memcmp(l2, saved_l2, sizeof(l2)) == 0);
    assert(dart_search(&dart, (char *)target_page + 1) == DART_PTR_ERR);
    cases++;

    l2[b] &= ~DART_PTE_VALID;
    assert(dart_search(&dart, target_page) == DART_PTR_ERR);
    l2[b] |= DART_PTE_VALID;
    l1[a] &= ~DART_PTE_VALID;
    assert(dart_search(&dart, target_page) == DART_PTR_ERR);
    dart.l1[ttbr] = NULL;
    assert(dart_search(&dart, target_page) == DART_PTR_ERR);
    cases += 3;
}

static void test_poll(void)
{
    const unsigned sids[] = {0, 4, 5, 255};
    for (unsigned n = 0; n < ARRAY_SIZE(sids); n++) {
        for (int failure = 0; failure < 2; failure++) {
            expected_sid = sids[n];
            event_count = diagnostics = 0;
            poll_result = failure ? -1 : 0;
            dart_dev_t dart = {.regs = fake_base, .device = expected_sid};
            dart_t8110_tlb_invalidate(&dart);
            assert(event_count == 3 && diagnostics == (unsigned)failure);
            cases++;
        }
    }
}

int main(int argc, char **argv)
{
    if (argc == 2) {
        if (strcmp(argv[1], "poll") == 0)
            test_poll();
        else if (strcmp(argv[1], "last-l1") == 0)
            search_case(&dart_t8110, 0, 2047, 0);
        else if (strcmp(argv[1], "last-l2") == 0)
            search_case(&dart_t8110, 0, 0, 2047);
        else
            return 64;
    } else {
        assert(argc == 1);
        test_poll();
        const struct dart_params *formats[] = {&dart_t8020, &dart_t6000, &dart_t8110};
        const unsigned indices[] = {0, 1, 2046, 2047};
        for (unsigned format = 0; format < ARRAY_SIZE(formats); format++)
            for (int ttbr = 0; ttbr < formats[format]->ttbr_count; ttbr++)
                for (unsigned a = 0; a < ARRAY_SIZE(indices); a++)
                    for (unsigned b = 0; b < ARRAY_SIZE(indices); b++)
                        search_case(formats[format], ttbr, indices[a], indices[b]);
    }
    printf("m1n1-dart-cases=%u passed; hardware_acceptance=false\n", cases);
    return 0;
}
