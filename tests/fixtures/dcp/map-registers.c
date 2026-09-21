/* SPDX-License-Identifier: MIT */
/* Owned-memory execution of the real register callback, not a kernel driver. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <string.h>

typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef u64 dma_addr_t;
#define __packed __attribute__((packed))
#define BIT(n) (1ULL << (n))
#define DCP_FW_NAME(n) n
#define DCP_FW_VERSION(x,y,z) (((x)<<16)|((y)<<8)|(z))
#define DMA_MAPPING_ERROR UINT64_MAX
#define DMA_BIDIRECTIONAL 0
#define WARN_ON(x) ((void)(x))
#define dev_warn(...) ((void)0)

struct device { int unused; };
struct resource { u64 start, end; };
struct apple_dcp {
    struct device *dev;
    u32 nr_disp_registers;
    struct resource *disp_registers[7];
};

static unsigned maps, error_checks;
static dma_addr_t mapping_result;
static struct device device;
static struct resource resource = { .start = 0x3503d0000, .end = 0x3503d3fff };
#define resource_size(r) ((r)->end - (r)->start + 1)

static __attribute__((unused)) dma_addr_t dma_map_resource(
    struct device *dev, u64 paddr, u64 size, int direction, unsigned long attrs)
{
    assert(dev == &device);
    assert(paddr == resource.start && size == 0x4000);
    assert(direction == DMA_BIDIRECTIONAL && attrs == 0);
    maps++;
    return mapping_result;
}

static __attribute__((unused)) bool dma_mapping_error(struct device *dev, dma_addr_t addr)
{
    assert(dev == &device && addr == mapping_result);
    error_checks++;
    return addr == DMA_MAPPING_ERROR;
}

/* Generated from the actual header structs and complete callback function. */
#include "callback.c"

static void reset(dma_addr_t result)
{
    mapping_result = result;
    maps = error_checks = 0;
}

int main(void)
{
    struct apple_dcp dcp = { .dev = &device, .nr_disp_registers = 1,
                            .disp_registers = { &resource } };
    struct dcp_map_reg_req req = { .index = 0, .flags = 0x80000100 };
    struct dcp_map_reg_resp resp, zero = {0};
    const u64 addresses[] = {0, 0x80004000, 0x120000000};
    memcpy(req.obj, "VORP", 4); /* PROV fourcc, little-endian on the wire. */
    assert(sizeof(req) == 16);
#if DCP_FW_VER >= DCP_FW_VERSION(13, 2, 0)
    assert(sizeof(resp) == 28);
#else
    assert(sizeof(resp) == 20);
#endif
    for (unsigned i = 0; i < sizeof(addresses)/sizeof(addresses[0]); i++) {
        reset(addresses[i]);
        resp = dcpep_cb_map_reg(&dcp, &req);
        assert(resp.ret == 0 && resp.addr == resource.start && resp.length == 0x4000);
#if DCP_FW_VER >= DCP_FW_VERSION(13, 2, 0)
        assert(resp.dva == addresses[i] && maps == 1);
#else
        assert(maps == 0 && error_checks == 0);
#endif
    }

    reset(DMA_MAPPING_ERROR);
    resp = dcpep_cb_map_reg(&dcp, &req);
#if DCP_FW_VER >= DCP_FW_VERSION(13, 2, 0)
    assert(resp.ret != 0 && maps == 1 && error_checks == 1);
    resp.ret = 0;
    assert(memcmp(&resp, &zero, sizeof(resp)) == 0);
#else
    assert(resp.ret == 0 && maps == 0 && error_checks == 0);
#endif

    req.flags = 0x100;
    reset(0x8000c000);
    for (unsigned repeat = 0; repeat < 3; repeat++) {
        resp = dcpep_cb_map_reg(&dcp, &req);
        assert(resp.ret == 0 && resp.addr == resource.start && resp.length == 0x4000);
#if DCP_FW_VER == DCP_FW_VERSION(14, 7, 0)
        assert(resp.dva == resource.start && maps == 0 && error_checks == 0);
#elif DCP_FW_VER >= DCP_FW_VERSION(13, 2, 0)
        assert(resp.dva == mapping_result && maps == repeat + 1 && error_checks == repeat + 1);
#else
        assert(maps == 0 && error_checks == 0);
#endif
    }
    for (u32 index = 1; index <= 8; index++) {
        req.index = index;
        reset(0x80004000);
        resp = dcpep_cb_map_reg(&dcp, &req);
        assert(resp.ret != 0 && maps == 0 && error_checks == 0);
        resp.ret = 0;
        assert(memcmp(&resp, &zero, sizeof(resp)) == 0);
    }
    req.index = UINT32_MAX;
    reset(0x80004000);
    resp = dcpep_cb_map_reg(&dcp, &req);
    assert(resp.ret != 0 && maps == 0 && error_checks == 0);
    return 0;
}
