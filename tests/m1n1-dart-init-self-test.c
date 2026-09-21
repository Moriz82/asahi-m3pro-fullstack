/* SPDX-License-Identifier: MIT */
/* Execute actual dart_init with fake registers and owned allocation slots.
 * Never invokes real MMIO, an Apple device, or dart_shutdown. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled in the offline container"
#endif
#ifndef M1N1_DART_SOURCE
#error "Define M1N1_DART_SOURCE as an absolute dart.c path"
#endif

static void *test_calloc(size_t count, size_t size);
static void *test_memalign(size_t alignment, size_t size);
static void test_free(void *pointer);
static u32 test_read32(u64 address);
static u32 test_set32(u64 address, u32 bits);
static void test_write32(u64 address, u32 value);
static int test_poll32(u64 address, u32 mask, u32 target, u32 timeout);
static void test_barrier(void);

#define calloc test_calloc
#define memalign test_memalign
#define free test_free
#define read32 test_read32
#define set32 test_set32
#define write32 test_write32
#define poll32 test_poll32
#undef dma_wmb
#define dma_wmb test_barrier
#include M1N1_DART_SOURCE
#undef calloc
#undef memalign
#undef free
#undef read32
#undef set32
#undef write32
#undef poll32
#undef dma_wmb
#undef printf

/* Non-PIE keeps the owned table addresses encodable in every TTBR format. */
static u64 retained[4][2048] __attribute__((aligned(16384)));
static u64 allocated[4][2048] __attribute__((aligned(16384)));
static const u64 zero_table[2048];
static u32 regs[0x2000 / 4], saved_regs[ARRAY_SIZE(regs)];
static const u64 fake_base = 0x12340000;
static struct { char op; u64 address; u32 value; } events[40];
static unsigned event_count, cases, allocation_calls, fail_at, invalid_frees, diagnostics;
static unsigned expected_allocations, premature_writes;
static bool live[4], fail_object;
static dart_dev_t *object;
#ifdef DART_ERR_UNCERTAIN
static void *metadata[4];
static unsigned metadata_count;
#endif
static const struct dart_params *params;

static void event(char op, u64 address, u32 value)
{
    assert(event_count < ARRAY_SIZE(events));
    events[event_count].op = op;
    events[event_count].address = address;
    events[event_count++].value = value;
}

static void *test_calloc(size_t count, size_t size)
{
#ifdef DART_ERR_UNCERTAIN
    if (size == sizeof(struct dart_owned_table)) {
        assert(count == 1 && metadata_count < ARRAY_SIZE(metadata));
        void *record = calloc(count, size); assert(record);
        metadata[metadata_count++] = record; return record;
    }
#endif
    assert(!object && count == 1 && size == sizeof(*object));
    event('c', 0, 0);
    if (fail_object)
        return NULL;
    object = calloc(count, size);
    assert(object);
    return object;
}

static void *test_memalign(size_t alignment, size_t size)
{
    assert(alignment == SZ_16K && size == SZ_16K && allocation_calls < 4);
    unsigned slot = allocation_calls++;
    event('a', slot, 0);
    if (allocation_calls == fail_at)
        return NULL;
    assert(!live[slot]);
    live[slot] = true;
    return allocated[slot];
}

static void test_free(void *pointer)
{
    if (!pointer)
        return;
#ifdef DART_ERR_UNCERTAIN
    for (unsigned i = 0; i < metadata_count; i++) if (pointer == metadata[i]) {
        free(pointer); metadata[i] = metadata[--metadata_count]; return;
    }
#endif
    event('f', (u64)pointer, 0);
    if (pointer == object) {
        free(object);
        object = NULL;
        return;
    }
    for (unsigned i = 0; i < ARRAY_SIZE(live); i++) {
        if (pointer == allocated[i] && live[i]) {
            live[i] = false;
            return;
        }
    }
    /* Detect interior, retained-table and duplicate frees without invoking UB. */
    invalid_frees++;
}

static unsigned register_index(u64 address)
{
    assert(address >= fake_base && address < fake_base + sizeof(regs));
    assert((address & 3) == 0);
    return (address - fake_base) / 4;
}

static u32 test_read32(u64 address)
{
    u32 value = regs[register_index(address)];
    event('r', address, value);
    return value;
}

static void check_prepared(void)
{
    bool ready = allocation_calls == expected_allocations;
    for (unsigned i = 0; i < expected_allocations; i++)
        ready = ready && live[i] && memcmp(allocated[i], zero_table, SZ_16K) == 0;
    premature_writes += !ready;
}

static u32 test_set32(u64 address, u32 bits)
{
    check_prepared();
    u32 value = regs[register_index(address)] |= bits;
    event('s', address, bits);
    return value;
}

static void test_write32(u64 address, u32 value)
{
    check_prepared();
    regs[register_index(address)] = value;
    event('w', address, value);
}

static void test_barrier(void)
{
    event('b', 0, 0);
}

static int test_poll32(u64 address, u32 mask, u32 target, u32 timeout)
{
    assert(target == 0 && timeout == 100);
    event('p', address, mask);
    return 0;
}

int debug_printf(const char *format, ...)
{
    assert(strcmp(format, "dart: device %d is too big for this DART type\n") == 0);
    diagnostics++;
    return 0;
}

static u32 ttbr_value(const void *table)
{
    u32 value = params->ttbr_valid |
                FIELD_PREP(params->ttbr_addr, (u64)table >> params->ttbr_shift);
    assert((FIELD_GET(params->ttbr_addr, value) << params->ttbr_shift) == (u64)table);
    return value;
}

static void expect(unsigned *cursor, char op, u64 address, u32 value)
{
    assert(*cursor < event_count);
    assert(events[*cursor].op == op && events[*cursor].address == address &&
           events[*cursor].value == value);
    (*cursor)++;
}

static void init_case(enum dart_type_t type, unsigned sid, bool locked, bool keep,
                      unsigned retained_mask, unsigned failure, bool object_failure)
{
    assert(!object);
    params = type == DART_T8110 ? &dart_t8110 :
             type == DART_T6000 ? &dart_t6000 : &dart_t8020;
    bool t8110 = type == DART_T8110;
    bool valid_sid = sid < (unsigned)params->sid_count;
    unsigned mask = locked || keep ? retained_mask : 0;
    expected_allocations = params->ttbr_count - __builtin_popcount(mask);
    event_count = allocation_calls = invalid_frees = diagnostics = premature_writes = 0;
    fail_at = failure;
    fail_object = object_failure;
    memset(live, 0, sizeof(live));
    memset(regs, 0xa5, sizeof(regs));
    memset(retained, 0x6d, sizeof(retained));
    memset(allocated, 0x3c, sizeof(allocated));
    u64 config = fake_base + (t8110 ? DART_T8110_PROTECT : DART_T8020_CONFIG);
    u32 lock_bit = t8110 ? DART_T8110_PROTECT_TTBR_TCR : DART_T8020_CONFIG_LOCK;
    regs[register_index(config)] = locked ? lock_bit : 0;
    u64 ttbr_base = fake_base + params->ttbr_off + 4 * params->ttbr_count * sid;
    if (valid_sid) {
        for (int i = 0; i < params->ttbr_count; i++)
            regs[register_index(ttbr_base + 4 * i)] =
                retained_mask & BIT(i) ? ttbr_value(retained[i]) : 0;
    }
    memcpy(saved_regs, regs, sizeof(regs));
    dart_dev_t *result = dart_init(fake_base, sid, keep, type);
    assert(invalid_frees == 0);
    for (unsigned i = 0; i < sizeof(retained); i++)
        assert(((const unsigned char *)retained)[i] == 0x6d);
    unsigned cursor = 0;
    expect(&cursor, 'c', 0, 0);
    if (object_failure || !valid_sid) {
        assert(!result && !object && !allocation_calls);
        assert(diagnostics == (unsigned)(!object_failure && !valid_sid));
        assert(memcmp(saved_regs, regs, sizeof(regs)) == 0);
        if (!object_failure) {
            assert(events[cursor++].op == 'f');
        }
        assert(cursor == event_count);
        cases++;
        return;
    }
    assert(!diagnostics);
    if (failure) {
        assert(!result && !object && allocation_calls == failure);
#ifdef DART_ERR_UNCERTAIN
        assert(!metadata_count);
#endif
        for (unsigned i = 0; i < ARRAY_SIZE(live); i++)
            assert(!live[i]);
        assert(memcmp(saved_regs, regs, sizeof(regs)) == 0);
        unsigned reads = 0, frees = 0;
        for (; cursor < event_count; cursor++) {
            assert(events[cursor].op == 'r' || events[cursor].op == 'a' ||
                   events[cursor].op == 'f');
            reads += events[cursor].op == 'r';
            frees += events[cursor].op == 'f';
        }
        assert(reads == 1U + ((locked || keep) ? params->ttbr_count : 0) +
               (unsigned)(t8110 && (locked || keep)));
        assert(frees == failure); /* Successful roots plus the object. */
        cases++;
        return;
    }
    assert(result && result == object && !premature_writes);
    assert(result->regs == fake_base && result->device == sid && result->type == type);
    assert(result->params == params && result->locked == locked && result->keep == keep);
    assert(result->vm_base == 0 && allocation_calls == expected_allocations);
    expect(&cursor, 'r', config, locked ? lock_bit : 0);
    if (t8110 && (locked || keep))
        expect(&cursor, 'r', fake_base + params->tcr_off + 4 * sid, 0xa5a5a5a5);
    if (locked || keep)
        for (int i = 0; i < params->ttbr_count; i++)
            expect(&cursor, 'r', ttbr_base + 4 * i,
                   saved_regs[register_index(ttbr_base + 4 * i)]);
    for (unsigned i = 0; i < expected_allocations; i++)
        expect(&cursor, 'a', i, 0);
    u64 enabled = fake_base + (t8110 ? DART_T8110_ENABLE_STREAMS + 4 * (sid >> 5) :
                                     DART_T8020_ENABLED_STREAMS);
    expect(&cursor, t8110 ? 'w' : 's', enabled, BIT(sid & 31));
    assert(regs[register_index(enabled)] == (t8110 ? BIT(sid & 31) :
           saved_regs[register_index(enabled)] | BIT(sid & 31)));
    unsigned allocated_index = 0;
    for (int i = 0; i < params->ttbr_count; i++) {
        if (mask & BIT(i)) {
            assert(result->l1[i] == retained[i]);
        } else {
            assert(result->l1[i] == allocated[allocated_index++]);
            expect(&cursor, 'w', ttbr_base + 4 * i, ttbr_value(result->l1[i]));
        }
        assert(regs[register_index(ttbr_base + 4 * i)] == ttbr_value(result->l1[i]));
    }
    for (int i = params->ttbr_count; i < DART_MAX_TTBR_COUNT; i++)
        assert(!result->l1[i]);
    if (!locked && !keep)
        expect(&cursor, 'w', DART_TCR(result), params->tcr_enabled);
    if (!t8110)
        expect(&cursor, 'w', fake_base + DART_T8020_STREAM_SELECT, BIT(sid));
    expect(&cursor, 'b', 0, 0);
    u64 command = fake_base + (t8110 ? DART_T8110_TLB_CMD : DART_T8020_STREAM_COMMAND);
    expect(&cursor, 'w', command, t8110 ? 0x100U | sid : DART_T8020_STREAM_COMMAND_INVALIDATE);
    expect(&cursor, 'p', command, t8110 ? DART_T8110_TLB_CMD_BUSY : DART_T8020_STREAM_COMMAND_BUSY);
    assert(cursor == event_count);
    /* Test-only teardown, not the unrelated hardware-affecting dart_shutdown. */
#ifdef DART_ERR_UNCERTAIN
    while (metadata_count) free(metadata[--metadata_count]);
#endif
    free(object);
    object = NULL;
    cases++;
}

int main(int argc, char **argv)
{
    if (argc == 2) {
        if (strcmp(argv[1], "invalid-free") == 0)
            init_case(DART_T8020, 5, false, false, 0, 2, false);
        else if (strcmp(argv[1], "leak") == 0)
            init_case(DART_T8020, 5, true, true, 0, 2, false);
        else if (strcmp(argv[1], "partial-write") == 0)
            init_case(DART_T8110, 5, true, true, 0, 1, false);
        else
            return 64;
    } else {
        assert(argc == 1);
        const enum dart_type_t types[] = {DART_T8020, DART_T6000, DART_T8110};
        const unsigned sids[] = {0, 4, 5, 31, 32, 255};
        for (unsigned t = 0; t < ARRAY_SIZE(types); t++) {
            unsigned roots = types[t] == DART_T8110 ? 1 : 4;
            for (unsigned s = 0; s < ARRAY_SIZE(sids); s++) {
                for (unsigned locked = 0; locked < 2; locked++) {
                    for (unsigned keep = 0; keep < 2; keep++) {
                        for (unsigned mask = 0; mask < BIT(roots); mask++) {
                            unsigned needed = roots - ((locked || keep) ? __builtin_popcount(mask) : 0);
                            init_case(types[t], sids[s], locked, keep, mask, 0, true);
                            for (unsigned failure = 0; failure <= needed; failure++)
                                init_case(types[t], sids[s], locked, keep, mask, failure, false);
                        }
                    }
                }
            }
        }
    }
    printf("m1n1-dart-init-cases=%u passed; hardware_acceptance=false\n", cases);
    return 0;
}
