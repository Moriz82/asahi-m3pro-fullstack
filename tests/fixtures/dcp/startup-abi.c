/* SPDX-License-Identifier: MIT */
/* Actual wire declarations and thunks, not firmware execution. */
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
#define trace_iomfb_callback(...) ((void)0)
#define trace_iomfb_swap_complete(...) ((void)0)
#define DCP_FW_VERSION(a, b, c) (((a) << 16) | ((b) << 8) | (c))
#define DCP_FW_NAME(x) x
#define NEW_ABI (DCP_FW_VER == DCP_FW_VERSION(14, 7, 0))
typedef int64_t ktime_t;
struct fake_crtc { int base; };
struct apple_dcp {
    u32 last_swap_id;
    bool crc_enabled;
    struct fake_crtc *crtc;
};
static unsigned flips, crcs;
static u32 crc_id;
static ktime_t ktime_get(void) { return 0x12345678; }
static void dcp_drm_crtc_page_flip(struct apple_dcp *dcp, ktime_t now)
{
    assert(dcp && now == ktime_get());
    flips++;
}
static void drm_crtc_add_crc_entry(int *base, bool present, u32 id, const u32 *crc)
{
    assert(base && present && *crc == 0);
    crc_id = id;
    crcs++;
}
typedef void (*dcp_callback_t)(struct apple_dcp *, void *, void *);
#include "types.inc"
#include "table.inc"
static struct {
    u32 in_len, out_len;
    unsigned char input[64];
    char tag[4];
    bool oob;
    dcp_callback_t callback;
    void *cookie;
} sent;
static void dcp_push(struct apple_dcp *dcp, bool oob,
                     const struct dcp_method_entry *method, u32 in_len,
                     u32 out_len, void *data, dcp_callback_t callback, void *cookie)
{
    assert(dcp && in_len <= sizeof(sent.input));
    memset(&sent, 0, sizeof(sent));
    sent.in_len = in_len;
    sent.out_len = out_len;
    memcpy(sent.input, data, in_len);
    memcpy(sent.tag, method->tag, 4);
    sent.oob = oob;
    sent.callback = callback;
    sent.cookie = cookie;
}
#include "thunks.inc"

static unsigned int cases;
static void unused_callback(struct apple_dcp *dcp, void *out, void *cookie)
{
    (void)dcp; (void)out; (void)cookie;
    assert(!"fixture does not execute a firmware completion");
}
static void check_swap(void)
{
    assert(sizeof(struct dcp_swap_start_req) == (NEW_ABI ? 16 : 24) && "A406 request size");
    assert(sizeof(struct dcp_swap_start_resp) == (NEW_ABI ? 8 : 24));
    assert(offsetof(struct dcp_swap_start_req, swap_id_null) == (NEW_ABI ? 12 : 20));
    assert(offsetof(struct dcp_swap_start_resp, ret) == (NEW_ABI ? 4 : 20));
    const u32 ids[] = {0, 0x12345678, UINT32_MAX};
    const u64 handle = UINT64_C(0x1020304050607080);
    struct apple_dcp dcp = {0};
    for (unsigned int i = 0; i < 3; i++) for (unsigned int null = 0; null < 2; null++) {
        struct dcp_swap_start_req req = {.swap_id = ids[i], .swap_id_null = null};
#if NEW_ABI && !defined(BASELINE)
        req.client = handle;
#else
        req.client.handle = handle;
#endif
        unsigned char expected[24] = {0};
        memcpy(expected, &ids[i], 4);
        memcpy(expected + 4, &handle, 8);
        expected[NEW_ABI ? 12 : 20] = null;
        dcp_swap_start(&dcp, null, &req, unused_callback, &dcp);
        assert(sent.in_len == (NEW_ABI ? 16 : 24) && sent.out_len == (NEW_ABI ? 8 : 24));
        assert(!memcmp(sent.tag, NEW_ABI ? "A406" : "A407", 4));
        assert(!memcmp(sent.input, expected, sent.in_len));
        assert(sent.oob == (bool)null && sent.callback == unused_callback && sent.cookie == &dcp);
        struct dcp_swap_start_resp reply = {0};
        u32 status = 0x87654321;
        memcpy(&reply, &ids[i], 4);
        memcpy((unsigned char *)&reply + (NEW_ABI ? 4 : 20), &status, 4);
        assert(reply.swap_id == ids[i] && reply.ret == status);
        cases++;
    }
}
static void check_power(void)
{
    assert(sizeof(struct dcp_set_power_state_req) == 12);
    assert(offsetof(struct dcp_set_power_state_req, unkint_null) == (NEW_ABI ? 11 : 9) && "A472 null flag offset");
    assert(sizeof(struct dcp_set_power_state_resp) == 8);
    struct apple_dcp dcp = {0};
    const u64 states[] = {0, 1, UINT64_MAX};
    for (unsigned int s = 0; s < 3; s++) for (unsigned int flags = 0; flags < (NEW_ABI ? 8 : 2); flags++)
    for (unsigned int null = 0; null < 2; null++) {
        struct dcp_set_power_state_req req = {.unklong = states[s], .unkbool = flags & 1, .unkint_null = null};
        unsigned char expected[12] = {0};
        memcpy(expected, &states[s], 8);
        expected[8] = flags & 1;
        expected[NEW_ABI ? 11 : 9] = null;
#if NEW_ABI && !defined(BASELINE)
        req.unkbool2 = (flags >> 1) & 1;
        req.unkbool3 = (flags >> 2) & 1;
        expected[9] = req.unkbool2;
        expected[10] = req.unkbool3;
#endif
        dcp_set_power_state(&dcp, false, &req, unused_callback, &dcp);
        assert(sent.in_len == 12 && sent.out_len == 8);
        assert(!memcmp(sent.tag, DCP_FW_VER < DCP_FW_VERSION(13, 2, 0) ? "A468" : "A472", 4));
        assert(!memcmp(sent.input, expected, 12));
        assert(sent.callback == unused_callback && sent.cookie == &dcp);
        cases++;
    }
}
static void check_tag(void)
{
    const char *tag = NEW_ABI ? "A448" : DCP_FW_VER < DCP_FW_VERSION(13, 2, 0) ? "A447" : "A449";
    assert(!memcmp(dcp_methods[dcpep_enable_disable_video_power_savings].tag, tag, 4) && "power-saving method tag");
    struct apple_dcp dcp = {0};
    const u32 flags[] = {0, 1, UINT32_MAX};
    for (unsigned int i = 0; i < 3; i++) {
        u32 value = flags[i];
        dcp_enable_disable_video_power_savings(&dcp, false, &value, NULL, NULL);
        assert(sent.in_len == 4 && sent.out_len == 4);
        assert(!memcmp(sent.tag, tag, 4) && !memcmp(sent.input, &value, 4));
        assert(!sent.callback && !sent.cookie);
        cases++;
    }
}
static void check_completion(void)
{
    const size_t size = NEW_ABI ? 1776 : DCP_FW_VER < DCP_FW_VERSION(13, 2, 0) ? 1750 : 1751;
    assert(sizeof(struct dc_swap_complete_resp) == size && "D589 structure size");
    assert(offsetof(struct dc_swap_complete_resp, swap_id) == 0);
    assert(offsetof(struct dc_swap_complete_resp, unkbool) == 4);
    assert(offsetof(struct dc_swap_complete_resp, swap_data) == 5);
#if NEW_ABI && !defined(BASELINE) && !defined(COMPLETION_BASELINE)
    assert(sizeof(((struct dc_swap_complete_resp *)0)->swap_data) == 34);
    assert(sizeof(((struct dc_swap_complete_resp *)0)->swap_info) == 1728);
    assert(offsetof(struct dc_swap_complete_resp, swap_info) == 39);
    assert(offsetof(struct dc_swap_complete_resp, unkint) == 1767);
    assert(offsetof(struct dc_swap_complete_resp, unkbool2) == 1771);
    assert(offsetof(struct dc_swap_complete_resp, swap_data_null) == 1772);
#else
    assert(sizeof(((struct dc_swap_complete_resp *)0)->swap_data) == 8);
    assert(offsetof(struct dc_swap_complete_resp, swap_info) == 13);
#endif
    struct fake_crtc crtc = {0};
    const u32 ids[] = {0, 0x12345678, UINT32_MAX};
    for (unsigned i = 0; i < 3; i++) for (unsigned null = 0; null < 2; null++)
    for (unsigned crc = 0; crc < 2; crc++) {
        unsigned char packet[1776], saved[1776];
        for (size_t j = 0; j < sizeof(packet); j++) packet[j] = (unsigned char)(j * 29 + 7);
        memcpy(packet, &ids[i], 4);
        packet[NEW_ABI ? 1772 : size - 1] = null;
        memcpy(saved, packet, sizeof(packet));
        struct dc_swap_complete_resp *resp = (void *)packet;
#if NEW_ABI && !defined(BASELINE) && !defined(COMPLETION_BASELINE)
        u32 count = 8;
        memcpy(packet + 1767, &count, 4);
        memcpy(saved, packet, sizeof(packet));
        assert(resp->unkint == count && resp->swap_data_null == null);
        assert(!memcmp(resp->swap_data, packet + 5, 34));
        assert(!memcmp(resp->swap_info, packet + 39, 1728));
        assert(resp->unkbool2 == packet[1771]);
#endif
        struct apple_dcp dcp = {.crc_enabled = crc, .crtc = &crtc};
        flips = crcs = 0;
        assert(trampoline_swap_complete(&dcp, 589, NULL, resp));
        assert(flips == 1 && crcs == crc && dcp.last_swap_id == ids[i]);
        if (crc) assert(crc_id == ids[i]);
        assert(!memcmp(packet, saved, sizeof(packet)));
        cases++;
    }
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "swap")) check_swap();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "power")) check_power();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "tag")) check_tag();
    if (!strcmp(argv[1], "all") || !strcmp(argv[1], "completion")) check_completion();
    printf("%u startup ABI cases pass; hardware_access=false\n", cases);
    return 0;
}
