/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#define __packed __attribute__((packed))
#define __maybe_unused __attribute__((unused))
#define DCP_FW_VERSION(x,y,z) (((x)<<16)|((y)<<8)|(z))
#define DCP_FIRMWARE_V_14_7 DCP_FW_VERSION(14,7,0)
#define IOMFB_MAX_CB 1000
#define DCP_PACKET_ALIGNMENT 0x40
#define DCP_CHANNEL_SIZE 0x8000
#define DCP_MAX_CALL_DEPTH 8
#define ALIGN(x,a) (((x)+(a)-1)&~((a)-1))
#define dev_warn(dev,...) ((void)(dev))
#define dev_err_probe(dev,err,...) ((void)(dev), (err))
#define trace_iomfb_callback(dcp,tag,name) ((void)(dcp), (void)(tag), (void)(name))
#define IS_ERR(p) ((uintptr_t)(p) >= (uintptr_t)-4095)
#define PTR_ERR(p) ((int)(intptr_t)(p))
struct device_node { bool target; };
struct device { struct device_node *of_node; };
struct clk { u64 rate; unsigned refs; };
struct apple_dcp;
typedef bool (*callback_fn)(struct apple_dcp *, int, void *, void *);
struct apple_dcp {
    struct device *dev;
    int fw_compat;
    struct clk *clk, *video_clk;
    callback_fn *cb_handlers;
};
enum dcp_context_id { CONTEXT };
struct dcp_channel {
    u8 depth;
    void *output[8], *cookies[8];
    callback_fn callbacks[8];
    u32 end[8];
    bool is_callback[8];
};
static struct dcp_channel channel;
static struct clk clocks[2] = {{CLOCK_FIXTURE_PIXEL,0}, {CLOCK_FIXTURE_VIDEO,0}};
static bool j514s = true;
static unsigned acquired, released, acks, cases;
static int fail_get;
static __maybe_unused bool of_device_is_compatible(struct device_node *node, const char *name)
{ assert(!strcmp(name, "apple,t6030-dcp")); return node->target; }
static __maybe_unused bool of_machine_is_compatible(const char *name)
{ assert(!strcmp(name, "apple,j514s")); return j514s; }
static u64 clk_get_rate(struct clk *clock) { assert(clock && !IS_ERR(clock)); return clock->rate; }
static __maybe_unused struct clk *devm_clk_get(struct device *dev, const char *name)
{
    (void)dev;
    unsigned index = name && !strcmp(name, "video");
    assert(!name || !strcmp(name, "pixel") || !strcmp(name, "video"));
    acquired++;
    if (fail_get == (int)acquired) return (void *)(intptr_t)-EAGAIN;
    clocks[index].refs++;
    return &clocks[index];
}
static __maybe_unused void devm_clk_put(struct device *dev, struct clk *clock)
{ (void)dev; assert(clock->refs); clock->refs--; released++; }
static struct dcp_channel *dcp_get_channel(struct apple_dcp *dcp, enum dcp_context_id context)
{ (void)dcp; assert(context == CONTEXT); return &channel; }
static __maybe_unused u8 dcp_push_depth(u8 *depth) { assert(*depth < 7); return (*depth)++; }
static void dcp_ack(struct apple_dcp *dcp, enum dcp_context_id context)
{ (void)dcp; assert(context == CONTEXT && channel.depth); channel.depth--; acks++; }

#include "code.inc"

/* The reply-copy macros also serve structured RPC outputs. */
struct reply_fixture { u8 bytes[65]; };
static struct reply_fixture reply_out(struct apple_dcp *dcp)
{
    (void)dcp;
    struct reply_fixture value;
    for (unsigned i=0; i<sizeof(value.bytes); i++) value.bytes[i]=(u8)(51+i);
    return value;
}
static struct reply_fixture reply_inout(struct apple_dcp *dcp, u32 *seed)
{
    struct reply_fixture value=reply_out(dcp);
    for (unsigned i=0; i<sizeof(value.bytes); i++) value.bytes[i]+=(u8)*seed;
    return value;
}
TRAMPOLINE_OUT(reply_out_trampoline, reply_out, struct reply_fixture);
TRAMPOLINE_INOUT(reply_inout_trampoline, reply_inout, u32, struct reply_fixture);

static void callback_case(struct apple_dcp *dcp, unsigned shift, u32 provider, u32 index, u64 expected)
{
    u8 *allocation = malloc(128);
    assert(allocation);
    memset(allocation, 0xa5, 128);
    u8 *packet = allocation + shift;
    struct dcp_packet_header header = {{'8','0','4','D'},8,8};
    memcpy(packet, &header, sizeof(header));
    memcpy(packet + sizeof(header), &provider, 4);
    memcpy(packet + sizeof(header) + 4, &index, 4);
    unsigned before = acks;
    dcpep_handle_cb(dcp, CONTEXT, packet, 28, 0);
    u64 actual;
    memcpy(&actual, packet + 20, 8);
    assert(actual == expected && acks == before + 1 && !channel.depth);
    assert(packet[28] == 0xa5);
    for (unsigned i=0; i<shift; i++) assert(allocation[i] == 0xa5);
    free(allocation);
    cases++;
}

int main(int argc, char **argv)
{
    assert(argc == 2 && sizeof(struct dcp_packet_header) == 12);
    struct device_node node = {.target=true};
    struct device device = {&node};
    callback_fn handlers[IOMFB_MAX_CB] = {[408]=trampoline_get_frequency};
    struct apple_dcp dcp = {&device, DCP_FW_VER, &clocks[0], &clocks[1], handlers};
#ifdef BASELINE
    /* Shift four aligns the old u64 output; isolate wrong-index from UB. */
    unsigned shift = !strcmp(argv[1], "index") ? 4 : 0;
    callback_case(&dcp, shift, 0x50524f56, 1, 0);
    return 0;
#else
    (void)argv;
    assert(sizeof(struct dcp_get_frequency_req) == 8);
    for (unsigned shift=0; shift<8; shift++) {
        u8 output[80]; u32 seed=17;
        for (unsigned input=0; input<2; input++) {
            memset(output,0xa5,sizeof(output));
            callback_fn call=input ? reply_inout_trampoline : reply_out_trampoline;
            assert(call(&dcp,0,output+shift,&seed));
            for (unsigned i=0; i<65; i++) assert(output[shift+i]==(u8)(51+i+(input ? seed : 0)));
            for (unsigned i=0; i<shift; i++) assert(output[i]==0xa5);
            for (unsigned i=shift+65; i<sizeof(output); i++) assert(output[i]==0xa5);
            cases++;
        }
    }
    for (unsigned target=0; target<2; target++) {
        node.target = target;
        for (unsigned shift=0; shift<8; shift++) {
            for (unsigned index=0; index<2; index++) {
                u64 expected = target && DCP_FW_VER == DCP_FIRMWARE_V_14_7 ? clocks[index].rate : clocks[0].rate;
                callback_case(&dcp, shift, 0x50524f56, index, expected);
            }
        }
    }
    node.target = true;
#if DCP_FW_VER == DCP_FIRMWARE_V_14_7
    callback_case(&dcp, 0, 0, 0, 0);
    callback_case(&dcp, 0, 0x50524f56, 2, 0);
    callback_case(&dcp, 0, 0x50524f56, UINT32_MAX, 0);
    clocks[1].rate = UINT32_MAX;
    callback_case(&dcp, 0, 0x50524f56, 1, UINT32_MAX);
    clocks[0].rate = 0;
    callback_case(&dcp, 0, 0x50524f56, 0, 0);
    for (u32 length=0; length<40; length++) {
        for (unsigned bad=0; bad<3; bad++) {
            u8 *packet = malloc(length ? length : 1);
            u8 *before = malloc(length ? length : 1);
            assert(packet && before);
            memset(packet, 0xa5, length);
            if (length >= 12) {
                struct dcp_packet_header header = {{'8','0','4','D'}, bad == 1 ? UINT32_MAX : 8, bad == 2 ? 7 : 8};
                memcpy(packet, &header, 12);
            }
            memcpy(before, packet, length);
            unsigned old_acks = acks;
            if (length < 28 || bad) {
                dcpep_handle_cb(&dcp, CONTEXT, packet, length, 0);
                assert(acks == old_acks && !channel.depth && !memcmp(packet, before, length));
                cases++;
            }
            free(packet); free(before);
        }
    }
#endif
    dcp.clk = dcp.video_clk = NULL;
    dcp.fw_compat = DCP_FIRMWARE_V_14_7;
    for (unsigned failed=0; failed<3; failed++) {
        acquired = released = 0; fail_get = failed;
        clocks[0].refs = clocks[1].refs = 0;
        int ret = dcp_get_display_clocks(&dcp);
        if (failed) {
            assert(ret == -EAGAIN && !dcp.clk && !dcp.video_clk);
            assert(acquired == failed && clocks[0].refs == (failed == 2));
        } else {
            assert(!ret && acquired == 2 && dcp.clk == &clocks[0] && dcp.video_clk == &clocks[1]);
            for (unsigned rebind=0; rebind<3; rebind++) {
                assert(!clock_bind(&dcp)); clock_unbind(&dcp);
                assert(acquired == 2 && released == 0 && clocks[0].refs == 1 && clocks[1].refs == 1);
            }
        }
        /* Fake platform devres release, not a real kernel lifetime test. */
        clocks[0].refs = clocks[1].refs = 0;
        dcp.clk = dcp.video_clk = NULL;
        cases++;
    }
    acquired = 0; fail_get = 0; j514s = false;
    assert(dcp_get_display_clocks(&dcp) == -ENODEV && !acquired);
    j514s = true; dcp.fw_compat = 0;
    assert(dcp_get_display_clocks(&dcp) == -ENODEV && !acquired);
    node.target = false;
    assert(!dcp_get_display_clocks(&dcp) && !acquired);
    assert(!clock_bind(&dcp) && acquired == 1 && dcp.clk == &clocks[0]);
    clock_unbind(&dcp);
    assert(released == 1 && !dcp.clk && !clocks[0].refs);
    cases += 3;
    printf("%u clock/callback cases pass\n", cases);
    return 0;
#endif
}
