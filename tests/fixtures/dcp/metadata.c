/* SPDX-License-Identifier: MIT */
/* Real callbacks and registrations; recording logging/work-queue fakes only. */
#include <assert.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
#define __packed __attribute__((packed))
#define __maybe_unused __attribute__((unused))
#define DCP_FW_VERSION(a, b, c) (((a) << 16) | ((b) << 8) | (c))
#define DCP_FW_NAME(x) x
#define NEW_ABI (DCP_FW_VER == DCP_FW_VERSION(14, 7, 0))
#define trace_iomfb_callback(...) ((void)0)
#define dev_dbg(...) ((void)0)
#define dev_info(...) ((void)0)
struct fake_work { unsigned calls; };
struct apple_connector { bool connected; struct fake_work hotplug_wq; };
struct apple_dcp {
    void *dev;
    bool main_display, during_modeset, valid_mode;
    struct apple_connector *connector;
    struct fake_work vblank_wq;
};
static void schedule_work(struct fake_work *work) { work->calls++; }
typedef bool (*handler_t)(struct apple_dcp *, int, void *, void *);
static bool trampoline_nop(struct apple_dcp *dcp, int tag, void *out, void *in) { return true; }
#include "types.inc"
#include "callbacks.inc"
#include "table.inc"
static unsigned cases;

static void frame_layout(void)
{
    assert(sizeof(struct frame_sync_props) == (NEW_ABI ? 56 : 28) && "frame-layout");
    assert(sizeof(struct dcp_set_frame_sync_props_req) == (NEW_ABI ? 60 : 32));
    assert(sizeof(struct dcp_set_frame_sync_props_resp) == (NEW_ABI ? 56 : 28));
    assert(offsetof(struct dcp_set_frame_sync_props_req, frame_sync_props_null) == (NEW_ABI ? 56 : 28));
#if NEW_ABI && defined(METADATA_HAS_HOTPLUG)
    assert(offsetof(struct frame_sync_props, updated) == 44);
    assert(offsetof(struct frame_sync_props, reserved) == 55);
    assert(sizeof(struct dcp_hotplug_req) == 88 && sizeof(struct dcp_hotplug_resp) == 76);
    assert(offsetof(struct dcp_hotplug_req, connected) == 0);
    assert(offsetof(struct dcp_hotplug_req, tiled_display) == 8);
    assert(offsetof(struct dcp_hotplug_req, unkbool) == 83);
    assert(offsetof(struct dcp_hotplug_req, tiled_display_null) == 84);
#endif
    cases++;
}

static void frame_reply(void)
{
    if (DCP_FW_VER == DCP_FW_VERSION(12, 3, 0)) {
        assert(!table[6]); cases++; return;
    }
    assert(table[6]);
    /* All 2048 update masks; noncanonical true flags still count as updates. */
    for (unsigned mask = 0; mask < (NEW_ABI ? 2048u : 2u); mask++)
    for (unsigned null = 0; null < 2; null++) {
        u8 input[60], saved[60], output[58], expected[56] = {0};
        for (unsigned i = 0; i < sizeof(input); i++) input[i] = (u8)(i * 29 + 7);
        for (unsigned i = 0; i < 11; i++) input[44+i] = (mask & (1u << i)) ? (u8)(i + 1) : 0;
        input[NEW_ABI ? 56 : 28] = null;
        if (NEW_ABI && !null) {
            memcpy(expected, input, 56);
            memset(expected + 44, 0, 11);
        }
        memcpy(saved, input, sizeof(input));
        memset(output, 0, sizeof(output));
        output[0] = output[(NEW_ABI ? 56 : 28) + 1] = 0xa5;
        struct apple_dcp dcp = {0}, before = dcp;
        assert(table[6](&dcp, 6, output + 1, input));
        assert(!memcmp(output + 1, expected, NEW_ABI ? 56 : 28) && "frame-reply");
        assert(output[0] == 0xa5 && output[(NEW_ABI ? 56 : 28) + 1] == 0xa5);
        assert(!memcmp(input, saved, sizeof(input)));
        assert(!memcmp(&dcp, &before, sizeof(dcp)));
        cases++;
    }
}

static void hotplug_reply(void)
{
    const u64 connections[] = {0, 1, UINT64_C(0x100000000), UINT64_MAX};
    for (unsigned c = 0; c < 4; c++) for (unsigned state = 0; state < 32; state++)
    for (unsigned flags = 0; flags < 4; flags++) {
        u8 input[88], saved[88], output[78] = {0}, expected[76] = {0};
        for (unsigned i = 0; i < sizeof(input); i++) input[i] = (u8)(i * 13 + 11);
        memcpy(input, &connections[c], 8);
        input[83] = flags & 1;
        input[84] = (flags >> 1) & 1;
        memcpy(saved, input, sizeof(input));
        if (NEW_ABI && !input[84]) memcpy(expected, input + 8, 75);
        output[0] = output[77] = 0xa5;
        struct apple_connector connector = {.connected = !!(state & 4)};
        struct apple_dcp dcp = {.main_display = !!(state & 1), .during_modeset = !!(state & 2),
            .valid_mode = !!(state & 8), .connector = (state & 16) ? NULL : &connector};
        const bool ignored = dcp.main_display || dcp.during_modeset;
        const bool connected = !!connections[c];
        const bool changed = dcp.connector && connector.connected != connected;
        const bool valid = dcp.valid_mode && (ignored || (connected && !changed));
        assert(table[576](&dcp, 576, output + 1, input));
        assert(!memcmp(output + 1, expected, 76) && "hotplug-reply");
        assert(output[0] == 0xa5 && output[77] == 0xa5);
        assert(!memcmp(input, saved, sizeof(input)));
        assert(dcp.valid_mode == valid);
        assert(dcp.vblank_wq.calls == (!ignored && !connected));
        assert(connector.hotplug_wq.calls == (!ignored && changed));
        assert(connector.connected == ((!ignored && dcp.connector) ? connected : !!(state & 4)));
        cases++;
    }
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "frame-layout")) frame_layout();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "frame-reply")) frame_reply();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "hotplug-reply")) hotplug_reply();
    printf("PASS: %u metadata cases; hardware_access=false\n", cases);
    return 0;
}
