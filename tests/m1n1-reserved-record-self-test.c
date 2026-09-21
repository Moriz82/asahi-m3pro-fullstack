/* SPDX-License-Identifier: MIT */
/* Production helper bodies plus real libfdt; no target operations. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libfdt.h"

typedef unsigned long u64;
_Static_assert(sizeof(u64) == 8, "loader requires a 64-bit unsigned long");
typedef uint32_t u32;
typedef struct { unsigned index; } dart_dev_t;
static void *dt, *adt;
static dart_dev_t darts[3] = {{0}, {1}, {2}};
static unsigned initialized, shut_down, shutdown_fail, checks;
static int init_fail = -1;
static void log_message(const char *fmt, ...) { (void)fmt; }
#define printf(...) log_message(__VA_ARGS__)
#define bail(...) do { log_message(__VA_ARGS__); return -1; } while (0)
#define bail_cleanup(...) do { log_message(__VA_ARGS__); ret = -1; goto err; } while (0)
#define SZ_16K 0x4000UL
#define ALIGN_UP(x, a) (((x) + (a) - 1) & ~((a) - 1))

#include "tuple.inc"
#include "nodes.inc"

static dart_dev_t *dt_init_dart_by_node(int node, unsigned index)
{
    assert(node >= 0 && index == 0 && initialized < 3);
    unsigned n = initialized++;
    return (int)n == init_fail ? NULL : &darts[n];
}
static bool dart_shutdown(dart_dev_t *dart)
{
    if (!dart) return true;
    shut_down |= 1U << dart->index;
    return !(shutdown_fail & (1U << dart->index));
}
static int dt_get_iommu_node(int node, unsigned index)
{
    int length;
    const fdt32_t *cells = fdt_getprop(dt, node, "iommus", &length);
    assert(index == 0 && cells && length == 8);
    return fdt_node_offset_by_phandle(dt, fdt32_to_cpu(cells[0]));
}
static int dt_device_set_reserved_mem_from_dart(int node, dart_dev_t *dart, const char *name,
                                               u32 phandle, u64 physical, u64 size)
{
    assert(dart && physical);
    return dt_device_set_reserved_mem(node, name, phandle, physical + 0x100000, size);
}
#include "regions.inc"

struct adt_segment_ranges { u64 phys, iova, remap; u32 size, unk; };
static struct adt_segment_ranges segments[2] = {
    {0x400000, 0x200000, 0x600000, 0x4000, 0},
    {0x800000, 0x900000, 0xa00000, 0x5000, 0},
};
static int adt_path_offset(const void *tree, const char *path)
{
    assert(tree == adt && !strcmp(path, "/asc"));
    return 1;
}
static const void *adt_getprop(const void *tree, int node, const char *name, u32 *length)
{
    assert(tree == adt && node == 1 && !strcmp(name, "segment-ranges"));
    *length = sizeof(segments);
    return segments;
}
#include "asc.inc"
#undef printf

static int node(const char *path)
{
    int n = fdt_path_offset(dt, path); assert(n >= 0); return n;
}
static void setstr(const char *path, const char *name, const char *value)
{ assert(!fdt_setprop_string(dt, node(path), name, value)); }
static void setup(bool reserved)
{
    assert(!fdt_create_empty_tree(dt, 8192));
    const char *names[] = {"aliases", "dcp", "disp", "pio", "dart", "reserved-memory"};
    for (unsigned i = 0; i < (reserved ? 6U : 5U); i++)
        assert(fdt_add_subnode(dt, 0, names[i]) >= 0);
    const char *paths[] = {"/dcp", "/disp", "/pio", "/dart"};
    for (unsigned i = 0; i < 4; i++) {
        assert(!fdt_setprop_u32(dt, node(paths[i]), "phandle", i + 1));
        setstr(paths[i], "status", "disabled");
        if (i < 3) {
            setstr("/aliases", paths[i] + 1, paths[i]);
            fdt32_t iommu[] = {cpu_to_fdt32(4), cpu_to_fdt32(i)};
            assert(!fdt_setprop(dt, node(paths[i]), "iommus", iommu, sizeof(iommu)));
        }
    }
    if (reserved) {
        assert(!fdt_setprop_u32(dt, node("/reserved-memory"), "#address-cells", 2));
        assert(!fdt_setprop_u32(dt, node("/reserved-memory"), "#size-cells", 2));
        assert(!fdt_setprop_empty(dt, node("/reserved-memory"), "ranges"));
    }
    initialized = shut_down = shutdown_fail = 0;
    init_fail = -1;
}
static int reserve_display(void)
{
    struct disp_mapping maps[] = {{"test", "framebuffer", true, true, true}};
    struct mem_region regions[] = {{0x400000, 0x4000}};
    return dt_add_reserved_regions("dcp", "disp", "pio", "framebuffer", maps, regions, 1);
}
static void display_failure(void)
{
    setup(false);
    assert(reserve_display() < 0 && "display reservation failure must reach caller");
    assert(shut_down == 7);
    for (unsigned i = 0; i < 3; i++) {
        setup(true); init_fail = (int)i;
        assert(reserve_display() < 0 && initialized == i + 1 && shut_down == (1U << i) - 1);
        checks++;
    }
    for (unsigned mask = 1; mask < 8; mask++) {
        setup(true); shutdown_fail = mask;
        assert(reserve_display() < 0 && shut_down == 7);
        checks++;
    }
    checks++;
}
static void asc_failure(void)
{
    setup(false);
    assert(dt_reserve_asc_firmware("/asc", NULL, "dcp", false, 0) < 0 &&
           "ASC reservation failure must reach caller");
    checks++;
}
static void tuple_boundary(void)
{
    for (unsigned old = 0; old <= 1; old++) {
        for (unsigned extra = 0; extra <= 60; extra++) {
            setup(true);
            if (old) assert(!dt_device_set_reserved_mem(node("/reserved-memory"), "test", 1, 0x100000001, 0x200000002));
            assert(!fdt_pack(dt));
            unsigned size = fdt_totalsize(dt);
            fdt_set_totalsize(dt, size + extra);
            int n = node("/reserved-memory"), before_length, after_length;
            const void *before = fdt_getprop(dt, n, "iommu-addresses", &before_length);
            unsigned char saved[20];
            if (before) { assert(before_length == 20); memcpy(saved, before, 20); }
            int ret = dt_device_set_reserved_mem(n, "test", 2, 0x123456789a, 0xabcdef0123);
            const void *after = fdt_getprop(dt, n, "iommu-addresses", &after_length);
            if (ret) {
                assert((before ? (after && after_length == 20 && !memcmp(saved, after, 20)) : !after) &&
                       "complete IOMMU record or unchanged property required");
            } else {
                assert(after && after_length == (int)((old + 1) * 20));
                if (old) assert(!memcmp(saved, after, 20));
                fdt32_t record[5]; memcpy(record, (const char *)after + old * 20, 20);
                assert(fdt32_to_cpu(record[0]) == 2);
                assert(fdt32_to_cpu(record[1]) == 0x12 && fdt32_to_cpu(record[2]) == 0x3456789a);
                assert(fdt32_to_cpu(record[3]) == 0xab && fdt32_to_cpu(record[4]) == 0xcdef0123);
            }
            assert(!fdt_check_header(dt));
            checks++;
        }
    }
}
static void healthy(void)
{
    setup(true); assert(!reserve_display() && initialized == 3 && shut_down == 7);
    int mem = node("/reserved-memory/framebuffer@400000"), length;
    const void *record = fdt_getprop(dt, mem, "iommu-addresses", &length);
    assert(record && length == 60);
    const char *paths[] = {"/dcp", "/disp", "/pio"};
    for (unsigned i = 0; i < 3; i++) {
        const fdt32_t *ref = fdt_getprop(dt, node(paths[i]), "memory-region", &length);
        assert(ref && length == 4 && fdt32_to_cpu(*ref) == fdt_get_phandle(dt, mem));
        const char *name = fdt_getprop(dt, node(paths[i]), "memory-region-names", &length);
        assert(name && length == 12 && !strcmp(name, "framebuffer"));
    }
    checks++;
    for (unsigned remap = 0; remap < 2; remap++) {
        setup(true); assert(!dt_reserve_asc_firmware("/asc", NULL, "dcp", remap, 0x100000000));
        const fdt32_t *refs = fdt_getprop(dt, node("/dcp"), "memory-region", &length);
        assert(refs && length == 8);
        for (unsigned i = 0; i < 2; i++) {
            mem = fdt_node_offset_by_phandle(dt, fdt32_to_cpu(refs[i])); assert(mem >= 0);
            const char *data = fdt_getprop(dt, mem, "iommu-addresses", &length);
            assert(data && length == 20);
            fdt64_t address, size; memcpy(&address, data + 4, 8); memcpy(&size, data + 12, 8);
            assert(fdt64_to_cpu(address) == ((remap ? segments[i].remap : segments[i].iova) | 0x100000000));
            assert(fdt64_to_cpu(size) == ALIGN_UP(segments[i].size, SZ_16K));
        }
        checks++;
    }
}
int main(int argc, char **argv)
{
    assert(argc == 2); dt = calloc(1, 8192); assert(dt);
    if (!strcmp(argv[1], "tuple")) tuple_boundary();
    else if (!strcmp(argv[1], "display")) display_failure();
    else if (!strcmp(argv[1], "asc")) asc_failure();
    else { assert(!strcmp(argv[1], "all")); tuple_boundary(); display_failure(); asc_failure(); healthy(); }
    free(dt); printf("PASS: actual reserved-memory helpers (%u cases)\n", checks);
}
