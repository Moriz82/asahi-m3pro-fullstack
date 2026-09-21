/* SPDX-License-Identifier: MIT */
/* Production SART + RTKit map/unmap; register addresses never leave this model. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "adt.h"
#include "utils.h"

static void *owned_calloc(size_t n, size_t size);
static void owned_free(void *p);
static u32 recorded_read(u64 address);
static void recorded_write(u64 address, u32 value);
#define calloc owned_calloc
#define free owned_free
#define read32 recorded_read
#define write32 recorded_write
#include M1N1_SART_SOURCE
#include M1N1_RTKIT_SOURCE
#undef calloc
#undef free
#undef read32
#undef write32
#undef printf

static bool map_succeeded(rtkit_dev_t *rtk, void *phys, size_t size, u64 *dva)
{
#ifdef DART_LIFECYCLE
    return rtkit_map(rtk, phys, size, dva) == 0;
#else
    return rtkit_map(rtk, phys, size, dva);
#endif
}
#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

#define BASE 0x12340000
#define LIMIT (1ULL << 44)
static u32 registers[0x100 / 4], version, property_size;
static unsigned reads, writes, frees;
#ifndef BASELINE
static unsigned cases;
#endif
static sart_dev_t *owner;
static bool fail_alloc, missing_property, bad_path, bad_reg, compatible, check_order, unaligned_property;
static unsigned char version_bytes[8];
static int fail_index;
#ifdef BASELINE
typedef u8 entry_flags;
#else
typedef u32 entry_flags;
#endif
static bool (*original_set)(sart_dev_t *, int, entry_flags, void *, size_t);
void *adt = (void *)1;

static unsigned address_offset(void) { return version == 4 ? 0x60 : 0x40; }
static unsigned size_offset(void) { return version == 4 ? 0xc0 : 0x80; }
static u32 flags_at(unsigned i)
{ return version < 3 ? registers[i] >> 24 : registers[i]; }
static void foreign_entry(unsigned i, u32 flags, u64 address, u32 pages)
{
    registers[i] = version < 3 ? (flags << 24) | pages : flags;
    registers[(address_offset() + 4 * i) / 4] = address >> 12;
    if (version >= 3) registers[(size_offset() + 4 * i) / 4] = pages;
}
static void *owned_calloc(size_t n, size_t size)
{
    assert(!owner && n == 1 && size == sizeof(*owner));
    if (fail_alloc) return NULL;
    owner = calloc(n, size); assert(owner); return owner;
}
static void owned_free(void *p)
{ if (p) { assert(p == owner); frees++; free(owner); owner = NULL; } }
static u32 recorded_read(u64 a)
{ assert(a >= BASE && a - BASE < sizeof(registers) && !(a & 3)); reads++; return registers[(a - BASE) / 4]; }
static void recorded_write(u64 a, u32 value)
{
    assert(a >= BASE && a - BASE < sizeof(registers) && !(a & 3));
    unsigned offset = a - BASE;
    if (check_order && offset >= address_offset() && offset < address_offset() + 64)
        assert(!flags_at((offset - address_offset()) / 4));
    if (check_order && version >= 3 && offset >= size_offset() && offset < size_offset() + 64)
        assert(!flags_at((offset - size_offset()) / 4));
    registers[offset / 4] = value; writes++;
}
int debug_printf(const char *format, ...) { (void)format; return 0; }
int adt_path_offset_trace(const void *tree, const char *path, int *trace)
{ (void)tree; (void)path; trace[0] = 0; return bad_path ? -1 : 1; }
int adt_get_reg(const void *tree, int *path, const char *name, int index, u64 *base, u64 *size)
{ (void)tree; (void)path; (void)name; (void)index; (void)size; *base = BASE; return bad_reg ? -1 : 0; }
const void *adt_getprop(const void *tree, int node, const char *name, u32 *size)
{
    (void)tree; (void)node; assert(!strcmp(name, "sart-version"));
    if (size) *size = property_size;
    if (missing_property) return NULL;
    if (unaligned_property) { memcpy(version_bytes + 1, &version, 4); return version_bytes + 1; }
    return &version;
}
bool adt_is_compatible(const void *tree, int node, const char *name)
{ (void)tree; (void)node; assert(!strcmp(name, "sart,t8015")); return compatible; }
/* The actual RTKit SART branch must not enter the unrelated DART branch. */
u64 iova_alloc(iova_domain_t *d, size_t sz) { (void)d; (void)sz; abort(); }
void iova_free(iova_domain_t *d, u64 addr, size_t sz) { (void)d; (void)addr; (void)sz; abort(); }
int dart_map(dart_dev_t *d, uintptr_t addr, void *p, size_t sz)
{ (void)d; (void)addr; (void)p; (void)sz; abort(); }
#ifdef DART_LIFECYCLE
bool dart_unmap(dart_dev_t *d, uintptr_t addr, size_t sz)
#else
void dart_unmap(dart_dev_t *d, uintptr_t addr, size_t sz)
#endif
{ (void)d; (void)addr; (void)sz; abort(); }

static bool failing_set(sart_dev_t *sart, int i, entry_flags flags, void *p, size_t sz)
{ return i == fail_index ? false : original_set(sart, i, flags, p, sz); }
static sart_dev_t *start(u32 v)
{
    assert(!owner); version = v; property_size = 4;
    memset(registers, 0, sizeof(registers)); reads = writes = frees = 0;
    fail_alloc = missing_property = bad_path = bad_reg = compatible = check_order = unaligned_property = false;
    fail_index = -1;
    sart_dev_t *s = sart_init("/arm-io/sart-ans"); assert(s && s == owner && !writes); return s;
}
static void finish(sart_dev_t *s)
{
#ifdef BASELINE
    sart_free(s);
#else
    assert(sart_free(s));
#endif
    assert(!owner);
}

int main(int argc, char **argv)
{
    assert(argc == 2);
#ifdef BASELINE
    sart_dev_t *s = start(3);
    if (!strcmp(argv[1], "wide-address")) { assert(!sart_add_allowed_region(s, (void *)LIMIT, SZ_4K)); return 0; }
    if (!strcmp(argv[1], "empty-region")) { assert(!sart_add_allowed_region(s, (void *)0x80000000, 0)); return 0; }
    if (!strcmp(argv[1], "foreign-free")) {
        foreign_entry(0, 0xff, 0x80000000, 1); finish(s); assert(flags_at(0) == 0xff); return 0;
    }
    if (!strcmp(argv[1], "foreign-remove")) {
        foreign_entry(0, 0xff, 0x80000000, 1); assert(!sart_remove_allowed_region(s, (void *)0x80000000, SZ_4K)); return 0;
    }
    if (!strcmp(argv[1], "opaque-flags")) {
        finish(s); foreign_entry(0, 0x100, 0x80000000, 1);
        s = sart_init("/arm-io/sart-ans"); assert(s && (s->protected_entries & 1)); return 0;
    }
    assert(sart_add_allowed_region(s, (void *)0x80000000, SZ_4K));
    if (!strcmp(argv[1], "duplicate")) { assert(!sart_add_allowed_region(s, (void *)0x80000000, SZ_4K)); return 0; }
    if (!strcmp(argv[1], "clear-order")) { check_order = true; assert(sart_remove_allowed_region(s, (void *)0x80000000, SZ_4K)); return 0; }
    assert(!strcmp(argv[1], "cleanup-failure"));
    original_set = s->set_entry; s->set_entry = failing_set; fail_index = 0;
    sart_free(s); assert(owner && !frees); return 0;
#else
    assert(!strcmp(argv[1], "all"));
    const u32 versions[] = {0, 2, 3, 4};
    for (unsigned v = 0; v < 4; v++) {
        sart_dev_t *s = start(versions[v]);
        u64 max_size = (version == 0 ? (1ULL << 19) - 1 : version == 2 ? (1ULL << 24) - 1 : (1ULL << 30) - 1) << 12;
        const u64 invalid[][2] = {{LIMIT, SZ_4K}, {LIMIT - SZ_4K, 2 * SZ_4K},
            {~0ULL, SZ_4K}, {0x80000000, 0}, {1, SZ_4K}, {0, 1},
            {0, max_size + SZ_4K}, {SZ_4K, ~0ULL - SZ_4K + 1}};
        for (unsigned i = 0; i < ARRAY_SIZE(invalid); i++) {
            u32 before[ARRAY_SIZE(registers)]; memcpy(before, registers, sizeof(before)); unsigned w = writes;
            assert(!sart_add_allowed_region(s, (void *)invalid[i][0], invalid[i][1]));
            assert(w == writes && !memcmp(before, registers, sizeof(before)) && !s->owned_entries); cases++;
        }
        const u64 valid[][2] = {{0, SZ_4K}, {LIMIT - SZ_4K, SZ_4K}, {0, max_size}};
        for (unsigned i = 0; i < ARRAY_SIZE(valid); i++) {
            check_order = true;
            assert(sart_add_allowed_region(s, (void *)valid[i][0], valid[i][1]));
            u32 flags; void *address; size_t size; s->get_entry(s, 0, &flags, &address, &size);
            assert(flags == s->flags_allow && (u64)address == valid[i][0] && size == valid[i][1]);
            assert(sart_remove_allowed_region(s, address, size) && !s->owned_entries && !flags_at(0)); cases++;
        }
        finish(s);
        for (unsigned slot = 0; slot < 16; slot++) {
            s = start(versions[v]); finish(s);
            for (unsigned i = 0; i < 16; i++) if (i != slot) foreign_entry(i, 1, 0x90000000 + i * SZ_4K, 1);
            s = sart_init("/arm-io/sart-ans"); assert(s);
            u32 before[ARRAY_SIZE(registers)]; memcpy(before, registers, sizeof(before));
            assert(sart_add_allowed_region(s, (void *)0x80000000, SZ_4K));
            assert(s->owned_entries == (1U << slot)); check_order = true;
            assert(sart_remove_allowed_region(s, (void *)0x80000000, SZ_4K));
            assert(!memcmp(before, registers, sizeof(before))); finish(s); cases++;
        }
        s = start(versions[v]); foreign_entry(0, 1, 0x90000000, 1);
        assert(!sart_remove_allowed_region(s, (void *)0x90000000, SZ_4K));
        finish(s); assert(flags_at(0) == 1); cases++;
        s = start(versions[v]); check_order = true;
        for (unsigned i = 0; i < 16; i++) assert(sart_add_allowed_region(s, (void *)(0x80000000ULL + i * SZ_4K), SZ_4K));
        assert(s->owned_entries == 0xffff && !sart_add_allowed_region(s, (void *)0x90000000, SZ_4K));
        for (unsigned i = 0; i < 16; i++) assert(sart_remove_allowed_region(s, (void *)(0x80000000ULL + ((i * 7) % 16) * SZ_4K), SZ_4K));
        assert(!s->owned_entries); finish(s); cases++;
        s = start(versions[v]); assert(sart_add_allowed_region(s, (void *)0x80000000, 2 * SZ_4K));
        unsigned w = writes;
        assert(!sart_add_allowed_region(s, (void *)0x80000000, SZ_4K));
        assert(!sart_add_allowed_region(s, (void *)0x80001000, 2 * SZ_4K));
        assert(!sart_add_allowed_region(s, (void *)0x7ffff000, 2 * SZ_4K)); assert(w == writes);
        assert(sart_add_allowed_region(s, (void *)0x80002000, SZ_4K)); finish(s); cases++;
        s = start(versions[v]); original_set = s->set_entry; s->set_entry = failing_set; fail_index = 0;
        assert(!sart_add_allowed_region(s, (void *)0x80000000, SZ_4K) && !s->owned_entries && !writes);
        fail_index = -1; assert(sart_add_allowed_region(s, (void *)0x80000000, SZ_4K));
        fail_index = 0; assert(!sart_remove_allowed_region(s, (void *)0x80000000, SZ_4K) && s->owned_entries == 1);
        assert(!sart_free(s) && owner == s && !frees && s->stopping);
        assert(!sart_add_allowed_region(s, (void *)0x90000000, SZ_4K));
        fail_index = -1; finish(s); assert(frees == 1); cases++;
        for (unsigned slot = 0; slot < 16; slot++) {
            s = start(versions[v]); check_order = true;
            for (unsigned i = 0; i < 16; i++)
                assert(sart_add_allowed_region(s, (void *)(0x80000000ULL + i * SZ_4K), SZ_4K));
            original_set = s->set_entry; s->set_entry = failing_set; fail_index = slot;
            assert(!sart_free(s) && s->owned_entries == ((0xffffU << slot) & 0xffff));
            for (unsigned i = 0; i < 16; i++) assert(flags_at(i) == (i < slot ? 0 : s->flags_allow));
            unsigned w = writes; fail_index = -1; finish(s);
            assert(writes - w == (16 - slot) * (version < 3 ? 3 : 4)); cases++;
        }
        s = start(versions[v]); rtkit_dev_t rtk = {.name = "fake", .sart = s};
        u64 dva = 0x1234; assert(!map_succeeded(&rtk, (void *)LIMIT, SZ_16K, &dva) && dva == 0x1234 && !writes);
        assert(map_succeeded(&rtk, (void *)0x80000000, SZ_16K, &dva) && dva == 0x80000000);
        original_set = s->set_entry; s->set_entry = failing_set; fail_index = 0;
        assert(!rtkit_unmap(&rtk, dva, SZ_16K) && s->owned_entries == 1);
        fail_index = -1; assert(rtkit_unmap(&rtk, dva, SZ_16K) && !s->owned_entries); finish(s); cases++;
    }
    for (u32 v = 3; v <= 4; v++) for (unsigned bit = 8; bit < 32; bit++) {
        sart_dev_t *s = start(v); finish(s); foreign_entry(0, 1U << bit, 0x90000000, 1);
        s = sart_init("/arm-io/sart-ans"); assert(s && s->protected_entries == 1);
        assert(sart_add_allowed_region(s, (void *)0x80000000, SZ_4K) && s->owned_entries == 2);
        finish(s); assert(flags_at(0) == (1U << bit)); cases++;
    }
    for (unsigned mode = 0; mode < 11; mode++) {
        sart_dev_t *s = start(3); finish(s); writes = frees = 0;
        fail_alloc = mode == 0; bad_path = mode == 1; bad_reg = mode == 2;
        missing_property = mode == 3 || mode == 9; compatible = mode == 9;
        if (mode == 4) version = 99;
        if (mode >= 5 && mode <= 8) property_size = mode == 5 ? 0 : mode == 6 ? 1 : mode == 7 ? 3 : 8;
        unaligned_property = mode == 10;
        s = sart_init("/arm-io/sart-ans");
        if (mode == 9) { assert(s && s->flags_allow == APPLE_SART0_FLAGS_ALLOW); finish(s); }
        else if (mode == 10) { assert(s && s->flags_allow == APPLE_SART3_FLAGS_ALLOW); finish(s); }
        else assert(!s && !owner && !writes);
        cases++;
    }
    assert(sart_free(NULL));
    assert(!sart_add_allowed_region(NULL, (void *)0x80000000, SZ_4K));
    assert(!sart_remove_allowed_region(NULL, (void *)0x80000000, SZ_4K)); cases++;
    printf("SART grant ownership + actual RTKit mapping: PASS (%u scenarios)\n", cases);
    return 0;
#endif
}
