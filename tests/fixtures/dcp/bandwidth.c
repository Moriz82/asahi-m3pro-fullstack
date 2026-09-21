/* SPDX-License-Identifier: MIT */
/* Actual callback/resource parser with owned metadata only. No MMIO/DMA. */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

typedef uint32_t u32;
typedef uint64_t u64;
#define __packed __attribute__((packed))
#define DCP_FW_NAME(n) n
#define DCP_FW_VERSION(x,y,z) (((x)<<16)|((y)<<8)|(z))
#define MAX_DISP_REGISTERS 7
#define dev_err(...) ((void)0)
#define REG_DOORBELL_BIT(index) (1U << (index))
struct device_node { bool target; };
struct device { struct device_node *of_node; };
struct resource { u64 start, end; };
#define resource_size(r) ((r)->end - (r)->start + 1)
struct of_phandle_args { struct device_node *np; int args_count; u32 args[3]; };
struct apple_dcp {
    struct device *dev;
    struct resource *disp_registers[7], disp_bw_scratch_res;
    u32 disp_bw_scratch_index, disp_bw_scratch_offset, disp_bw_doorbell_index, index;
};
static struct device_node node;
static struct device device = {&node};
static struct of_phandle_args args;
static struct resource resource;
static int parse_error, resource_error, puts;

static __attribute__((unused)) bool of_device_is_compatible(struct device_node *np, const char *name)
{
    assert(np == &node && !strcmp(name, "apple,t6030-dcp"));
    return np->target;
}
static int of_parse_phandle_with_args(struct device_node *np, const char *name,
                                      const char *cells, int index, struct of_phandle_args *out)
{
    assert(np == &node && !strcmp(name, "apple,bw-scratch"));
    assert(!strcmp(cells, "#apple,bw-scratch-cells") && index == 0);
    *out = args;
    return parse_error;
}
static int of_address_to_resource(struct device_node *np, u32 index, struct resource *out)
{
    assert(np == &node && index == 0);
    *out = resource;
    return resource_error;
}
static void of_node_put(struct device_node *np) { assert(np == &node); puts++; }

#include "callback.c"

static void word64(unsigned char *wire, unsigned offset, u64 value)
{
    for (unsigned i = 0; i < 8; i++) wire[offset + i] = value >> (8 * i);
}

int main(void)
{
    assert(sizeof(struct dcp_rt_bandwidth) == 60);
    assert(offsetof(struct dcp_rt_bandwidth, reg_scratch) == 8);
#if DCP_FW_VER == DCP_FW_VERSION(14, 7, 0) && !defined(BASELINE)
    assert(offsetof(struct dcp_rt_bandwidth, scratch_size) == 44);
    assert(offsetof(struct dcp_rt_bandwidth, ret) == 56);
#endif
    for (unsigned target = 0; target < 2; target++) {
        for (unsigned doorbell = 0; doorbell < 2; doorbell++) {
            if (target && doorbell) continue; /* no target doorbell contract */
            node.target = target;
            struct resource scratch = {0x3503d0000, 0x3503d3fff};
            struct resource bell = {0x12340000, 0x12343fff};
            struct apple_dcp dcp = {.dev = &device, .disp_bw_scratch_index = 5,
                .disp_bw_scratch_offset = 0x988, .disp_bw_doorbell_index = doorbell ? 6 : 0,
                .index = 2, .disp_registers = {[5] = &scratch, [6] = &bell}};
            unsigned char expected[60] = {0};
            word64(expected, 8, 0x3503d0988);
            if (doorbell) {
                word64(expected, 16, bell.start);
                expected[28] = 4;
                expected[44] = 4;
            }
#if DCP_FW_VER == DCP_FW_VERSION(14, 7, 0)
            if (target) expected[44] = 8;
#endif
            struct dcp_rt_bandwidth result = dcpep_cb_rt_bandwidth(&dcp);
            assert(!memcmp(&result, expected, sizeof(expected)));
        }
    }

    const u64 sizes[] = {0, 1, 3, 4, 7, 8, 0x4000};
    const u32 offsets[] = {0, 1, 4, 7, 8, 0x988, 0x3ff8, 0x3ffc, 0xffffffff};
    for (unsigned target = 0; target < 2; target++) {
        node.target = target;
        for (unsigned s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++) {
            for (unsigned o = 0; o < sizeof(offsets)/sizeof(offsets[0]); o++) {
                struct apple_dcp dcp = {.dev = &device};
                u32 width = target ? 8 : 4;
                args = (struct of_phandle_args){&node, 3, {0, 5, offsets[o]}};
                resource = (struct resource){0x3503d0000, 0x3503d0000 + sizes[s] - 1};
                puts = 0;
                int ret = dcp_get_bw_scratch_reg(&dcp, 5);
                bool valid = sizes[s] >= width && offsets[o] <= sizes[s] - width;
                assert((ret == 0) == valid && puts == 1);
                if (valid) {
                    assert(dcp.disp_bw_scratch_index == 5 && dcp.disp_bw_scratch_offset == offsets[o]);
                    assert(dcp.disp_registers[5] == &dcp.disp_bw_scratch_res);
                } else {
                    assert(!dcp.disp_bw_scratch_index && !dcp.disp_bw_scratch_offset);
                    assert(dcp.disp_registers[5] == NULL);
                }
            }
        }
    }
    for (unsigned mode = 0; mode < 5; mode++) {
        struct apple_dcp dcp = {.dev = &device};
        args = (struct of_phandle_args){&node, mode == 0 ? 2 : 3, {0, mode == 1 ? 4 : mode == 2 ? 7 : 5, 0x988}};
        resource = (struct resource){0x3503d0000, 0x3503d3fff};
        parse_error = mode == 3 ? -ENOENT : 0;
        resource_error = mode == 4 ? -EINVAL : 0;
        puts = 0;
        assert(dcp_get_bw_scratch_reg(&dcp, 5) < 0);
        assert(puts == (mode == 3 ? 0 : 1));
        assert(dcp.disp_registers[5] == NULL && !dcp.disp_bw_scratch_index);
    }
    return 0;
}
