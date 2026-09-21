/* SPDX-License-Identifier: MIT */
/* Actual C library/helper with owned page arrays and recorded registers.
 * Never reads a device, live physical memory, or a host hardware register. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"
#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static void *owned_calloc(size_t n, size_t size);
static void *owned_memalign(size_t alignment, size_t size);
static void owned_free(void *pointer);
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
#include "mapping.inc"
#undef calloc
#undef memalign
#undef free
#undef read32
#undef write32
#undef set32
#undef poll32
#undef dma_wmb
#undef printf

static u64 retained[32][2048] __attribute__((aligned(16384)));
static u64 allocated[16][2048] __attribute__((aligned(16384)));
static u32 registers[0x2000 / 4];
static bool live[16], check_flush, has_preallocation;
static dart_dev_t *object;
#ifdef DART_ERR_UNCERTAIN
static void *metadata[32];
static unsigned metadata_count;
#endif
static unsigned calls, fail_allocation, writes, polls, barriers, cases, next_retained;
static u64 flushed_hash, model_limit;
static const u64 fake_base = 0x12340000, physical = 0x80000000;
static enum dart_type_t model_type;
static bool model_four;
static unsigned roots;
void *adt = (void *)1;

static u64 tables_hash(void)
{
    u64 hash = 0;
    for (unsigned n = 0; n < ARRAY_SIZE(retained); n++)
        for (unsigned i = 0; i < 2048; i++)
            hash = (hash ^ retained[n][i]) * 0x100000001b3ULL;
    for (unsigned n = 0; n < ARRAY_SIZE(allocated); n++)
        for (unsigned i = 0; i < 2048; i++)
            hash = (hash ^ allocated[n][i]) * 0x100000001b3ULL;
    return hash;
}

static void *owned_calloc(size_t n, size_t size)
{
#ifdef DART_ERR_UNCERTAIN
    if (size == sizeof(struct dart_owned_table)) {
        assert(n == 1 && metadata_count < ARRAY_SIZE(metadata));
        void *record = calloc(n, size); assert(record);
        metadata[metadata_count++] = record; return record;
    }
#endif
    assert(!object && n == 1 && size == sizeof(*object));
    object = calloc(n, size);
    assert(object);
    return object;
}

static void *owned_memalign(size_t alignment, size_t size)
{
    assert(alignment == SZ_16K && size == SZ_16K);
    if (++calls == fail_allocation)
        return NULL;
    for (unsigned i = 0; i < ARRAY_SIZE(live); i++) {
        if (!live[i]) {
            live[i] = true;
            memset(allocated[i], 0x5a, SZ_16K);
            return allocated[i];
        }
    }
    assert(!"fixture allocation pool exhausted");
    return NULL;
}

bool is_heap(void *pointer)
{
    for (unsigned i = 0; i < ARRAY_SIZE(live); i++)
        if (pointer == allocated[i])
            return live[i];
    return false;
}

static void owned_free(void *pointer)
{
    if (!pointer)
        return;
#ifdef DART_ERR_UNCERTAIN
    for (unsigned i = 0; i < metadata_count; i++) if (pointer == metadata[i]) {
        free(pointer); metadata[i] = metadata[--metadata_count]; return;
    }
#endif
    if (pointer == object) {
        free(object);
        object = NULL;
        return;
    }
    for (unsigned i = 0; i < ARRAY_SIZE(live); i++) {
        if (pointer == allocated[i]) {
            assert(live[i]);
            if (check_flush)
                assert(polls && tables_hash() == flushed_hash);
            live[i] = false;
            return;
        }
    }
    assert(!"free of retained, interior or unrelated pointer");
}

static unsigned reg_index(u64 address)
{
    assert(address >= fake_base && address < fake_base + sizeof(registers) && !(address & 3));
    return (address - fake_base) / 4;
}
static u32 recorded_read(u64 address) { return registers[reg_index(address)]; }
static void recorded_write(u64 address, u32 value)
{ registers[reg_index(address)] = value; writes++; }
static u32 recorded_set(u64 address, u32 value)
{ u32 v = recorded_read(address) | value; recorded_write(address, v); return v; }
static void recorded_barrier(void) { barriers++; }
static int recorded_poll(u64 address, u32 mask, u32 value, u32 timeout)
{
    assert(address == fake_base + (model_type == DART_T8110 ? 0x80 : 0x20));
    assert(mask == (model_type == DART_T8110 ? 0x80000000U : 4U));
    assert(!value && timeout == 100);
    polls++; flushed_hash = tables_hash(); return 0;
}
int debug_printf(const char *format, ...) { (void)format; return 0; }

int adt_path_offset(const void *tree, const char *path)
{ assert(tree == adt && !strcmp(path, "/fixture")); return 1; }
const struct adt_property *adt_get_property(const void *tree, int node, const char *name)
{
    static const struct adt_property property = {.size = 16};
    assert(tree == adt && node == 1 && !strcmp(name, "pt-region-5"));
    return has_preallocation ? &property : NULL;
}
int adt_setprop(void *tree, int node, const char *name, void *value, size_t size)
{
    (void)tree; (void)node; (void)name; (void)value; (void)size;
    assert(!"unverified legacy metadata mutation"); return -1;
}

/* Independent wire representation; not the production PTE constructor. */
static u64 wire_pte(u64 address)
{
    unsigned shift = model_type == DART_T8020 ? 14 : 10;
    u64 encoded = (address >> 14) << shift;
    assert((encoded >> shift << 14) == address);
    return encoded | 1;
}
static u64 *wire_table(u64 entry)
{
    u64 mask = model_type == DART_T8020 ? 0xffffffc000ULL :
               model_type == DART_T6000 ? 0xfffffffc00ULL : 0x3ffffffc00ULL;
    unsigned shift = model_type == DART_T8020 ? 14 : 10;
    return (u64 *)((entry & mask) >> shift << 14);
}
static u64 *model_entry(u64 iova, bool create)
{
    if (iova >= model_limit)
        return NULL;
    u64 *table = object->l1[model_four ? 0 : iova >> 36];
    if (!table)
        return NULL;
    for (int shift = model_four ? 36 : 25; shift >= 25; shift -= 11) {
        u64 *entry = &table[(iova >> shift) & 2047];
        if (!(*entry & 1)) {
            if (!create)
                return NULL;
            assert(next_retained < ARRAY_SIZE(retained));
            *entry = wire_pte((u64)retained[next_retained++]);
        }
        table = wire_table(*entry);
    }
    return &table[(iova >> 14) & 2047];
}

static void reset(enum dart_type_t type, bool four, unsigned bits, bool keep, bool locked, bool retain)
{
    assert(!object);
    for (unsigned i = 0; i < ARRAY_SIZE(live); i++)
        assert(!live[i]);
    memset(retained, 0, sizeof(retained)); memset(allocated, 0, sizeof(allocated));
    memset(registers, 0, sizeof(registers));
    model_type = type; model_four = four; roots = type == DART_T8110 ? 1 : 4;
    model_limit = four ? 1ULL << bits : (u64)roots << 36;
    calls = fail_allocation = writes = polls = barriers = 0;
    check_flush = has_preallocation = false; next_retained = 4;
    unsigned sid = 5;
    registers[reg_index(fake_base + (type == DART_T8110 ? 0x200 : 0x60))] =
        locked ? (type == DART_T8110 ? 1 : 0x8000) : 0;
    registers[reg_index(fake_base + (type == DART_T8110 ? 0x1000 : 0x100) + 4 * sid)] =
        type == DART_T8110 ? 1 | (four ? 8 : 0) : 128;
    registers[0] = 14U << 24;
    registers[2] = (42U << 24) | (bits << 16);
    if (retain) {
        for (unsigned i = 0; i < roots; i++) {
            u32 value = type == DART_T8110 ? ((u64)retained[i] >> 14 << 2) | 1 :
                                          ((u64)retained[i] >> 12) | 0x80000000;
            registers[reg_index(fake_base + (type == DART_T8110 ? 0x1400 : 0x200) +
                                4 * roots * sid + 4 * i)] = value;
        }
    }
    dart_dev_t *result = dart_init(fake_base, sid, keep, type);
    assert(result && result == object);
    if (retain)
        for (unsigned i = 0; i < roots; i++)
            assert(object->l1[i] == retained[i]);
    check_flush = true;
}

static void finish(void)
{
    assert(object);
    dart_shutdown(object);
    assert(!object);
#ifdef DART_ERR_UNCERTAIN
    assert(!metadata_count);
#endif
    for (unsigned i = 0; i < ARRAY_SIZE(live); i++)
        assert(!live[i]);
    cases++;
}

static void retained_case(bool four, unsigned bits, u64 base, unsigned pages)
{
    reset(DART_T8110, four, bits, true, true, true);
    for (unsigned n = 0; n < pages; n++)
        *model_entry(base + n * SZ_16K, true) = wire_pte(physical + n * SZ_16K);
    if (four && bits < 47)
        retained[0][1U << (bits - 36)] = 1; /* Out-of-aperture poison must not be traversed. */
    u64 before = tables_hash(); unsigned old_writes = writes, old_calls = calls;
    for (unsigned n = 0; n < pages; n++) {
        const unsigned offsets[] = {0, 7, SZ_16K - 1};
        for (unsigned j = 0; j < ARRAY_SIZE(offsets); j++) {
            assert((u64)dart_translate(object, base + n * SZ_16K + offsets[j]) ==
                   physical + n * SZ_16K + offsets[j]); cases++;
        }
        assert(dart_search(object, (void *)(physical + n * SZ_16K)) == base + n * SZ_16K); cases++;
    }
    assert(dart_get_mapping(object, "/fixture", physical, pages * SZ_16K) == base); cases++;
    assert(dart_get_mapping(object, "/fixture", physical, pages * SZ_16K - 7) == base); cases++;
    assert(!dart_translate_silent(object, model_limit));
    assert(!dart_translate_silent(object, UINT64_MAX));
    assert(before == tables_hash() && old_writes == writes && old_calls == calls);
    if (pages > 2) {
        u64 *middle = model_entry(base + SZ_16K, false), saved = *middle;
        *middle = 0;
        assert(DART_IS_ERR(dart_get_mapping(object, "/fixture", physical, pages * SZ_16K))); cases++;
        *middle = wire_pte(physical + 8 * SZ_16K);
        assert(DART_IS_ERR(dart_get_mapping(object, "/fixture", physical, pages * SZ_16K))); cases++;
        *middle = saved;
    }
    finish();
    assert(before == tables_hash()); /* No owned tables or mapping edits in this case. */
}

static void mutation_case(enum dart_type_t type, bool four, u64 base, unsigned failure)
{
    reset(type, four, 42, true, true, true);
    *model_entry(0, true) = wire_pte(physical); /* Neighbor must survive high-root operations. */
    u64 old_low = *model_entry(0, false);
    fail_allocation = calls + failure;
    int result = dart_map(object, base, (void *)(physical + 8 * SZ_16K), 4 * SZ_16K);
    if (failure && calls >= fail_allocation) {
        assert(result == -1);
        for (unsigned n = 0; n < 4; n++) {
            u64 *entry = model_entry(base + n * SZ_16K, false);
            assert(!entry || !(*entry & 1));
        }
    } else {
        assert(!result);
        for (unsigned n = 0; n < 4; n++) {
            assert((u64)dart_translate(object, base + n * SZ_16K) == physical + (8 + n) * SZ_16K);
            assert((*model_entry(base + n * SZ_16K, false) & ~0xfff0000000000000ULL) ==
                   (wire_pte(physical + (8 + n) * SZ_16K) | (0xfffULL << 40) |
                    (type == DART_T8020 ? 2 : 0)));
            cases++;
        }
        /* A collision after one successful page rolls only that page back. */
        u64 collision = base + 5 * SZ_16K;
        assert(!dart_map(object, collision, (void *)(physical + 20 * SZ_16K), SZ_16K));
        assert(dart_map(object, base + 4 * SZ_16K, (void *)physical, 2 * SZ_16K) == -1);
        assert(!dart_translate_silent(object, base + 4 * SZ_16K));
        assert((u64)dart_translate(object, collision) == physical + 20 * SZ_16K);
        dart_unmap(object, collision, SZ_16K);
        dart_unmap(object, base, 4 * SZ_16K);
        assert(*model_entry(0, false) == old_low);
        assert(!dart_translate_silent(object, base));
        dart_free_l2(object, base & ~(SZ_32M - 1));
        dart_free_l2(object, (base + 3 * SZ_16K) & ~(SZ_32M - 1));
    }
    assert(*model_entry(0, false) == old_low);
    finish();
}

static void invalid_ranges(bool four)
{
    reset(DART_T8110, four, 42, true, true, true);
    *model_entry(0, true) = wire_pte(0); /* Valid PA zero must not be offered as free IOVA. */
    assert(dart_find_iova(object, 0, SZ_16K) == SZ_16K); cases++;
    const u64 addresses[] = {1, model_limit, UINT64_MAX & ~(SZ_16K - 1)};
    for (unsigned i = 0; i < ARRAY_SIZE(addresses); i++) {
        unsigned old_writes = writes, old_calls = calls; u64 before = tables_hash();
        assert(dart_map(object, addresses[i], (void *)physical, SZ_16K) == -1);
        dart_unmap(object, addresses[i], SZ_16K);
        dart_free_l2(object, addresses[i]);
        assert(DART_IS_ERR(dart_find_iova(object, addresses[i], SZ_16K)));
        assert(before == tables_hash() && old_writes == writes && old_calls == calls); cases++;
    }
    unsigned old_writes = writes, old_calls = calls; u64 before = tables_hash();
    assert(dart_map(object, model_limit - SZ_16K, (void *)physical, 2 * SZ_16K) == -1);
    assert(dart_map(object, SZ_16K, (void *)(1ULL << 42), SZ_16K) == -1);
    assert(dart_map(object, SZ_16K, (void *)physical, SIZE_MAX & ~(SZ_16K - 1)) == -1);
    assert(DART_IS_ERR(dart_find_iova(object, 0, 0)));
    assert(DART_IS_ERR(dart_find_iova(object, 0, SIZE_MAX & ~(SZ_16K - 1))));
    assert(dart_find_iova(object, model_limit - SZ_16K, SZ_16K) == model_limit - SZ_16K);
    assert(before == tables_hash() && old_writes == writes && old_calls == calls); cases++;
    dart_free_l2(object, 0); /* A retained leaf must not be freed, even if empty. */
    *model_entry(0, false) = 0;
    dart_free_l2(object, 0);
    assert(old_writes == writes && old_calls == calls); cases++;
    finish();
}

static void invalid_mode(unsigned which)
{
    reset(DART_T8110, true, 42, true, true, true);
    /* Drop only the fixture-owned handle. Original retained arrays stay intact. */
    free(object); object = NULL; writes = polls = calls = 0; check_flush = false;
    unsigned tcr = reg_index(fake_base + 0x1000 + 4 * 5);
    switch (which) {
        case 0: registers[tcr] = 8; break;
        case 1: registers[tcr] = 11; break;
        case 2: registers[0] = 12U << 24; break;
        case 3: registers[2] = (42U << 24) | (36U << 16); break;
        case 4: registers[2] = (42U << 24) | (48U << 16); break;
        case 5: registers[2] = (41U << 24) | (42U << 16); break;
        case 6: registers[tcr] = 9 | 128; break;
        default: assert(!"invalid test selector");
    }
    assert(!dart_init(fake_base, 5, true, DART_T8110));
    assert(!object && !writes && !polls && !calls); cases++;
}

static void original_failure(const char *mode)
{
    if (!strcmp(mode, "nonzero-root-unmap")) {
        reset(DART_T8020, false, 38, true, true, true);
        *model_entry(0, true) = wire_pte(physical);
        *model_entry(1ULL << 36, true) = wire_pte(physical + SZ_16K);
        dart_unmap(object, 1ULL << 36, SZ_16K);
        assert(*model_entry(0, false) == wire_pte(physical));
        assert(!*model_entry(1ULL << 36, false));
    } else {
        reset(DART_T8110, true, 42, true, true, true);
        *model_entry(1ULL << 40, true) = wire_pte(physical);
        if (!strcmp(mode, "four-level-translation"))
            assert((u64)dart_translate(object, 1ULL << 40) == physical);
        else if (!strcmp(mode, "four-level-search"))
            assert(dart_search(object, (void *)physical) == 1ULL << 40);
        else
            assert(!"unknown test mode");
    }
    cases++; finish();
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (strcmp(argv[1], "all"))
        original_failure(argv[1]);
    else {
        const unsigned widths[] = {37, 42, 47};
        for (unsigned w = 0; w < ARRAY_SIZE(widths); w++) {
            const u64 bases[] = {0, SZ_16K, (1ULL << 25) - 2 * SZ_16K,
                                 (1ULL << 36) - 2 * SZ_16K, 1ULL << 36};
            for (unsigned i = 0; i < ARRAY_SIZE(bases); i++)
                retained_case(true, widths[w], bases[i], 4);
            retained_case(true, widths[w], (1ULL << widths[w]) - SZ_16K, 1);
        }
        retained_case(false, 36, (1ULL << 25) - 2 * SZ_16K, 4);
        for (unsigned four = 0; four < 2; four++) {
            for (unsigned failure = 0; failure <= 4; failure++)
                mutation_case(DART_T8110, four,
                              (four ? 1ULL << 36 : 1ULL << 25) - 2 * SZ_16K, failure);
            invalid_ranges(four);
        }
        for (unsigned type = 0; type < 2; type++)
            for (unsigned root = 1; root < 4; root++)
                mutation_case(type ? DART_T6000 : DART_T8020, false,
                              ((u64)root << 36) - 2 * SZ_16K, 0);
        for (unsigned i = 0; i < 7; i++)
            invalid_mode(i);
        for (unsigned keep = 0; keep < 2; keep++) {
            for (unsigned locked = 0; locked < 2; locked++) {
                if (!keep && !locked)
                    continue;
                reset(DART_T8110, true, 42, keep, locked, true);
                *model_entry(1ULL << 40, true) = wire_pte(physical);
                assert((u64)dart_translate(object, 1ULL << 40) == physical);
                assert(registers[reg_index(fake_base + 0x1000 + 20)] == 9);
                finish();
                assert(registers[reg_index(fake_base + 0x1000 + 20)] == 9);
            }
        }
        reset(DART_T8110, true, 42, true, true, true);
        u64 *reserved_bits = model_entry(1ULL << 40, true);
        *reserved_bits = wire_pte(physical) | (3ULL << 38);
        assert((u64)dart_translate(object, 1ULL << 40) == physical);
        assert(dart_search(object, (void *)physical) == 1ULL << 40);
        cases++; finish();
        reset(DART_T8110, true, 42, true, true, true);
        u64 before = tables_hash(); unsigned old_writes = writes, old_calls = calls;
        assert(!dart_setup_pt_region(object, "/fixture", 5, 1ULL << 40));
        has_preallocation = true;
        assert(dart_setup_pt_region(object, "/fixture", 5, 1ULL << 40) == -2);
        assert(before == tables_hash() && old_writes == writes && old_calls == calls); cases++;
        finish();
        reset(DART_T8110, true, 42, true, true, true);
        retained[0][1] = 1; /* Null intermediate pointer, not a physical-zero leaf. */
        assert(!dart_translate_silent(object, 1ULL << 36));
        assert(dart_search(object, (void *)physical) == DART_PTR_ERR);
        finish();
        reset(DART_T8110, false, 36, false, false, false);
        assert(!dart_map(object, SZ_16K, (void *)physical, SZ_16K));
        finish(); /* Fresh contexts still use the original two memory-table levels. */
        original_failure("four-level-translation");
        original_failure("four-level-search");
        original_failure("nonzero-root-unmap");
    }
    printf("PASS: %u retained-level/lifecycle cases; actual C, owned arrays, no hardware\n", cases);
    return 0;
}
