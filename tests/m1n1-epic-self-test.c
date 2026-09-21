/* SPDX-License-Identifier: MIT */
/* Real AFK and property parser; owned memory and fake mailbox/time/DMA boundaries. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "afk.h"
#include "utils.h"
static void *test_malloc(size_t size);
static void *test_calloc(size_t count, size_t size);
static void test_free(void *pointer);
#define malloc test_malloc
#define calloc test_calloc
#define free test_free
#include M1N1_AFK_SOURCE
#include M1N1_PARSER_SOURCE
#undef malloc
#undef calloc
#undef free
#undef printf

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static afk_epic_t afk;
static afk_epic_ep_t epic;
static unsigned char memory[8192] __attribute__((aligned(16384)));
static unsigned char command_rx[16384], command_tx[16384];
static void *allocations[128];
static unsigned live, allocations_seen, fail_allocation, cases, sends, calls, last_channel;
static unsigned rtk_allocs, rtk_frees, fail_rtk_allocation;
static bool injecting, fail_send, wipe_notification, nested, require_snapshot, noise, mutate_snapshot;
static bool nested_allowed;
static int callback_error;
static unsigned noise_events, noise_type;
static u64 ticks;
static struct afk_qe *notification;
static size_t notification_size;
static struct epic_cmd captured_command;
static u16 captured_sequence;

int debug_printf(const char *fmt, ...) { (void)fmt; return 0; }
void hexdump(const void *data, size_t size) { (void)data; (void)size; }
u64 timeout_calculate(u32 usec) { return ticks + usec; }
bool timeout_expired(u64 deadline) { ticks += 10000; return ticks >= deadline; }
bool rtkit_can_recv(rtkit_dev_t *rtk) { assert(rtk == (void *)1); return noise; }
int rtkit_recv(rtkit_dev_t *rtk, struct rtkit_message *msg)
{
    assert(rtk == (void *)1);
    if (!noise)
        return 0;
    *msg = (struct rtkit_message){.ep = 0x20, .msg = FIELD_PREP(RBEP_TYPE, noise_type)};
    noise_events++;
    return 1;
}
bool rtkit_start_ep(rtkit_dev_t *rtk, u8 ep)
{ assert(rtk == (void *)1 && ep == 0x20); return true; }
bool rtkit_send(rtkit_dev_t *rtk, const struct rtkit_message *msg)
{
    assert(rtk == (void *)1 && msg->ep == 0x20);
    if (injecting)
        return true;
    sends++;
    if (fail_send)
        return false;
    if (FIELD_GET(RBEP_TYPE, msg->msg) == RBEP_SEND) {
        afk_epic_ep_t peer = {.rx = epic.tx};
        struct afk_qe *qe;
        assert(afk_epic_rx(&peer, &qe) == 1);
        if (qe->type == TYPE_COMMAND) {
            struct epic_hdr *hdr = (void *)qe->data;
            struct epic_sub_hdr *sub = (void *)(hdr + 1);
            memcpy(&captured_command, sub + 1, sizeof(captured_command));
            captured_sequence = sub->seq;
        }
        afk_epic_rx_ack(&peer);
    }
    return true;
}
bool rtkit_alloc_buffer(rtkit_dev_t *rtk, struct rtkit_buffer *buffer, size_t size)
{
    assert(rtk == (void *)1);
    if (++rtk_allocs == fail_rtk_allocation || buffer->bfr || !size || size > 16384)
        return false;
    *buffer = (struct rtkit_buffer){.bfr = rtk_allocs == 1 ? command_rx : command_tx,
        .dva = (1ULL << 40) + rtk_allocs * 16384, .sz = 16384, .owned = true};
    return true;
}
bool rtkit_free_buffer(rtkit_dev_t *rtk, struct rtkit_buffer *buffer)
{
    assert(rtk == (void *)1);
    if (buffer->bfr)
        rtk_frees++;
    *buffer = (struct rtkit_buffer){0};
    return true;
}

static void *test_malloc(size_t size)
{
    if (mutate_snapshot && notification) {
        notification->size = (u32)-1;
        mutate_snapshot = false;
    }
    /* Simulate firmware immediately recycling an acknowledged notification. */
    if (wipe_notification && notification && *epic.rx.rptr != 0) {
        memset(notification, 0xee, notification_size);
        wipe_notification = false;
    }
    assert(size && size <= 1 << 20);
    if (++allocations_seen == fail_allocation)
        return NULL;
    void *pointer = malloc(size);
    assert(pointer && live < 128);
    allocations[live++] = pointer;
    return pointer;
}
static void *test_calloc(size_t count, size_t size)
{
    assert(!count || size <= (size_t)-1 / count);
    void *pointer = test_malloc(count * size);
    if (pointer)
        memset(pointer, 0, count * size);
    return pointer;
}
static void test_free(void *pointer)
{
    if (!pointer)
        return;
    unsigned i = 0;
    while (i < live && allocations[i] != pointer)
        i++;
    assert(i < live);
    allocations[i] = allocations[--live];
    free(pointer);
}

static int service_call(afk_epic_service_t *service, u32 index, const void *data,
                        size_t size, void *reply, size_t reply_size)
{
    assert(index == 7 && size == 4 && reply_size == 4);
    assert(!memcmp(data, "ABCD", 4));
    if (require_snapshot)
        assert((uintptr_t)data < (uintptr_t)memory ||
               (uintptr_t)data >= (uintptr_t)memory + sizeof(memory));
    calls++;
    last_channel = service->channel;
    if (nested) {
        unsigned before = sends;
        int ret = afk_epic_command(&epic, 1, 0xc0, "nested", 6, NULL, NULL);
        assert(nested_allowed ? ret == 0 : ret < 0);
        assert(sends == before + (nested_allowed ? 1 : 0));
    }
    memcpy(reply, "WXYZ", 4);
    return callback_error;
}
static void service_init(afk_epic_service_t *service, const char *name, const char *class, s64 unit)
{ (void)service; (void)name; assert(class && class[0]); (void)unit; calls++; }
static const afk_epic_service_ops_t operations[] = {
    {.name = "test", .call = service_call, .init = service_init}, {.name = ""}};

static void reset(void)
{
    assert(live == 0);
    memset(memory, 0, sizeof(memory));
    memset(command_rx, 0xa5, sizeof(command_rx));
    memset(command_tx, 0, sizeof(command_tx));
    afk = (afk_epic_t){.rtk = (void *)1};
    epic = (afk_epic_ep_t){.ep = 0x20, .afk = &afk, .started = true, .ops = operations,
        .buf = {.bfr = memory, .sz = sizeof(memory)}, .buf_size = sizeof(memory),
        .txbuf = {.bfr = command_tx, .dva = (1ULL << 40) + 0x8000, .sz = sizeof(command_tx)},
        .rxbuf = {.bfr = command_rx, .dva = (1ULL << 40) + 0x4000, .sz = sizeof(command_rx)}};
    afk.endpoint[0] = &epic;
    *(u32 *)memory = *(u32 *)(memory + 2304) = 2048;
    assert(afk_rb_init(&epic, &epic.rx, 0, 2240));
    assert(afk_rb_init(&epic, &epic.tx, 2304, 2240));
    epic.num_channels = 2;
    for (unsigned i = 0; i < 2; i++)
        epic.services[i] = (afk_epic_service_t){.enabled = true, .ops = operations,
                                              .epic = &epic, .channel = i + 1};
    sends = calls = last_channel = allocations_seen = fail_allocation = 0;
    rtk_allocs = rtk_frees = fail_rtk_allocation = 0;
    injecting = fail_send = wipe_notification = nested = require_snapshot = noise = mutate_snapshot = false;
    callback_error = 0;
    nested_allowed = false;
    noise_events = 0;
    noise_type = RBEP_INIT_ACK;
    notification = NULL;
    notification_size = 0;
    ticks = 0;
    captured_command = (struct epic_cmd){0};
    captured_sequence = 0;
}

static void queue(u32 channel, u32 type, u8 category, u16 subtype, u16 seq,
                  const void *data, size_t size)
{
    unsigned char bytes[1536] = {0};
    assert(size <= sizeof(bytes) - sizeof(struct epic_hdr) - sizeof(struct epic_sub_hdr));
    struct epic_hdr *hdr = (void *)bytes;
    struct epic_sub_hdr *sub = (void *)(hdr + 1);
    hdr->version = 2;
    sub->version = 4;
    sub->length = size;
    sub->category = category;
    sub->type = subtype;
    sub->seq = seq;
    if (size)
        memcpy(sub + 1, data, size);
    afk_epic_ep_t peer = {.afk = &afk, .ep = 0x20, .tx = epic.rx};
    injecting = true;
    assert(afk_epic_tx(&peer, channel, type, bytes,
                       sizeof(*hdr) + sizeof(*sub) + size) == 1);
    injecting = false;
}
static void reply(u32 channel, u16 seq, size_t rxlen)
{
    struct epic_cmd cmd = {.rxbuf = epic.rxbuf.dva, .rxlen = rxlen};
    queue(channel, TYPE_REPLY, CAT_REPLY, 0xc0, seq, &cmd, sizeof(cmd));
}
static void notify(u32 channel)
{
    struct { struct epic_std_service_ap_call call; char data[4]; } PACKED packet = {
        .call = {.type = 7, .len = 4}, .data = {'A','B','C','D'}};
    notification = epic.rx.buf;
    notification_size = sizeof(struct afk_qe) + sizeof(struct epic_hdr) +
                        sizeof(struct epic_sub_hdr) + sizeof(packet);
    queue(channel, TYPE_NOTIFY, CAT_NOTIFY, SUBTYPE_STD_SERVICE, 44, &packet, sizeof(packet));
}
static int command(void)
{ return afk_epic_command(&epic, 1, 0xc0, "command", 7, NULL, NULL); }

static void envelope(void)
{
    reset(); notify(1);
    struct afk_qe *qe = epic.rx.buf;
    qe->size = sizeof(struct epic_hdr) + sizeof(struct epic_sub_hdr) - 1;
    afk_epic_notify_handler(&epic);
    assert(epic.rx.failed && !calls && !live);
    cases++;
}
static void lifetime(void)
{
    reset(); notify(1); reply(1, 0, 0);
    wipe_notification = true;
    require_snapshot = true;
    assert(command() == 0 && calls == 1 && !live);
    cases++;
}
static void notify_channel(void)
{
    reset(); notify(2); reply(1, 0, 0);
    assert(command() == 0 && calls == 1 && last_channel == 2 && !live);
    cases++;
}
static void reply_channel(void)
{
    reset(); reply(2, 0, 0); reply(1, 0, 0);
    assert(command() == 0 && *epic.rx.rptr == *epic.rx.wptr && !live);
    cases++;
}
static void reply_sequence(void)
{
    reset(); reply(1, 17, 0); reply(1, 0, 0);
    assert(command() == 0 && *epic.rx.rptr == *epic.rx.wptr && !live);
    cases++;
}
static void reply_address(void)
{
    reset();
    struct epic_cmd cmd = {.rxbuf = 1234, .rxlen = 4};
    queue(1, TYPE_REPLY, CAT_REPLY, 0xc0, 0, &cmd, sizeof(cmd));
    char output[4] = {'X','X','X','X'};
    size_t size = sizeof(output);
    assert(afk_epic_command(&epic, 1, 0xc0, "cmd", 3, output, &size) < 0);
    assert(!memcmp(output, "XXXX", 4) && size == sizeof(output) && !live);
    cases++;
}

static size_t put_tag(unsigned char *bytes, size_t pos, unsigned type, unsigned size)
{
    pos = ALIGN_UP(pos, 4);
    u32 tag = (type << 24) | size;
    memcpy(bytes + pos, &tag, 4);
    return pos + 4;
}
static size_t put_string(unsigned char *bytes, size_t pos, const char *text)
{
    size_t length = strlen(text);
    pos = put_tag(bytes, pos, DCP_TYPE_STRING, length);
    memcpy(bytes + pos, text, length);
    return pos + length;
}
static size_t properties(unsigned char *bytes, bool duplicate_name)
{
    memset(bytes, 0, 512);
    bytes[0] = DCP_PARSE_HEADER;
    size_t pos = put_tag(bytes, 4, DCP_TYPE_DICTIONARY, duplicate_name ? 4 : 3);
    pos = put_string(bytes, pos, "EPICName");
    pos = put_string(bytes, pos, "screen");
    pos = put_string(bytes, pos, "EPICProviderClass");
    pos = put_string(bytes, pos, "test");
    pos = put_string(bytes, pos, "EPICUnit");
    pos = put_tag(bytes, pos, DCP_TYPE_INT64, 64);
    s64 unit = 7;
    memcpy(bytes + pos, &unit, 8);
    pos += 8;
    if (duplicate_name) {
        pos = put_string(bytes, pos, "EPICName");
        pos = put_string(bytes, pos, "duplicate");
    }
    return pos;
}
static void skip_truncated(void)
{
    reset();
    unsigned char bytes[512];
    size_t size = properties(bytes, false);
    u32 dict = (DCP_TYPE_DICTIONARY << 24) | 4;
    memcpy(bytes + 4, &dict, 4);
    size = put_string(bytes, size, "unknown");
    size = put_tag(bytes, size, DCP_TYPE_BLOB, 0x100);
    struct dcp_parse_ctx ctx;
    char *name, *class;
    s64 unit = -1;
    assert(parse(bytes, size, &ctx) == 0);
    assert(parse_epic_service_init(&ctx, &name, &class, &unit) < 0);
    assert(!name && !class && !live);
    cases++;
}
static void duplicate_property(void)
{
    reset();
    unsigned char bytes[512];
    size_t size = properties(bytes, true);
    struct dcp_parse_ctx ctx;
    char *name, *class;
    s64 unit = -1;
    assert(parse(bytes, size, &ctx) == 0);
    assert(parse_epic_service_init(&ctx, &name, &class, &unit) < 0);
    assert(!name && !class && !live);
    cases++;
}
static void parser_oom(void)
{
    reset();
    unsigned char bytes[512];
    size_t size = properties(bytes, false);
    struct dcp_parse_ctx ctx;
    char *name, *class;
    s64 unit = -1;
    assert(parse(bytes, size, &ctx) == 0);
    fail_allocation = 1;
    assert(parse_epic_service_init(&ctx, &name, &class, &unit) < 0);
    assert(!name && !class && !live);
    cases++;
}
static void interface_timeout(void)
{
    reset(); epic.num_channels = 0;
    epic.rxbuf = epic.txbuf = (struct rtkit_buffer){0};
    assert(afk_epic_start_interface(&epic, NULL, 1, 16384, 16384) < 0);
    assert(!rtk_allocs && !live);
    cases++;
}

static void parser_unaligned(void)
{
    reset();
    unsigned char bytes[513];
    size_t size = properties(bytes + 1, false);
    struct dcp_parse_ctx ctx;
    char *name, *class;
    s64 unit = -1;
    assert(parse(bytes + 1, size, &ctx) == 0);
    assert(parse_epic_service_init(&ctx, &name, &class, &unit) == 0 && unit == 7);
    test_free(name); test_free(class);
    assert(!live);
    cases++;
}
static void work_noise(void)
{
    reset(); noise = true;
    assert(afk_epic_work(&afk, epic.ep) == 0 && noise_events == 16);
    cases++;
}
static void command_nested(void)
{
    reset(); notify(1); reply(1, 0, 0); nested = true;
    assert(command() == 0 && calls == 1 && sends == 2 && !live);
    assert(!memcmp(command_tx, "command", 7));
    cases++;
}

#ifndef BASELINE
static void message_bounds(void)
{
    for (unsigned size = 0; size < sizeof(struct epic_hdr) + sizeof(struct epic_sub_hdr); size++) {
        reset(); notify(1);
        ((struct afk_qe *)epic.rx.buf)->size = size;
        afk_epic_notify_handler(&epic);
        assert(epic.rx.failed && !calls && !live);
        cases++;
    }
    for (unsigned mode = 0; mode < 8; mode++) {
        reset(); notify(1);
        struct afk_qe *qe = epic.rx.buf;
        struct epic_hdr *hdr = (void *)qe->data;
        struct epic_sub_hdr *sub = (void *)(hdr + 1);
        struct epic_std_service_ap_call *call = (void *)(sub + 1);
        switch (mode) {
            case 0: hdr->version = 1; break;
            case 1: sub->version = 2; break;
            case 2: sub->length++; break;
            case 3: sub->length = (u32)-1; break;
            case 4: sub->inline_len = sub->length + 1; break;
            case 5: sub->length = sizeof(*call) - 1; break;
            case 6: call->len = 5; break;
            case 7: call->len = (u32)-1; break;
        }
        afk_epic_notify_handler(&epic);
        assert(epic.rx.failed && !calls && !live);
        cases++;
    }
    for (unsigned allocation = 1; allocation <= 2; allocation++) {
        reset(); notify(1); fail_allocation = allocation;
        afk_epic_notify_handler(&epic);
        assert(epic.rx.failed && !calls && !live);
        assert((*epic.rx.rptr == 0) == (allocation == 1));
        cases++;
    }
    reset(); notify(1); mutate_snapshot = true;
    afk_epic_notify_handler(&epic);
    assert(epic.rx.failed && !calls && !live && *epic.rx.rptr == 0);
    reset(); notify(1); fail_send = true;
    afk_epic_notify_handler(&epic);
    assert(epic.rx.failed && epic.tx.failed && calls == 1 && !live);
    reset(); notify(1); callback_error = 7;
    afk_epic_notify_handler(&epic);
    assert(epic.rx.failed && calls == 1 && !sends && !live);
    cases += 3;
}

static void command_cases(void)
{
    reset(); notify(1); reply(1, 0, 0);
    nested = nested_allowed = require_snapshot = wipe_notification = true;
    afk_epic_notify_handler(&epic);
    assert(!epic.rx.failed && !epic.command_pending && calls == 1 && sends == 2 && !live);
    assert(*epic.rx.rptr == *epic.rx.wptr);
    cases++;

    reset(); reply(1, 0, 0); epic.command_pending = true;
    assert(afk_epic_work(&afk, 0x21) == 0 && *epic.rx.rptr == 0);
    epic.recv_handler = afk_epic_notify_handler;
    noise = true; noise_type = RBEP_RECV;
    assert(afk_epic_poll(&afk, 0x21, false) == 0 && *epic.rx.rptr == 0 && !live);
    assert(afk_epic_work(&afk, epic.ep) == EPIC_DATA_READY);
    cases++;

    for (unsigned size = 0; size <= sizeof(struct epic_cmd) + 8; size++) {
        reset();
        unsigned char bytes[64] = {0};
        struct epic_cmd cmd = {.rxbuf = epic.rxbuf.dva, .rxlen = 4};
        memcpy(bytes, &cmd, sizeof(cmd));
        queue(1, TYPE_REPLY, CAT_REPLY, 0xc0, 0, bytes, size);
        unsigned char output[4] = {0};
        size_t amount = sizeof(output);
        int ret = afk_epic_command(&epic, 1, 0xc0, "abc", 3, output, &amount);
        bool valid = size >= offsetof(struct epic_cmd, rxcookie);
        assert((ret == 0) == valid && !live);
        if (valid) {
            assert(!memcmp(output, command_rx, 4) && amount == 4 && !epic.command_pending);
        } else {
            assert(output[0] == 0 && amount == 4 && epic.command_pending && epic.rx.failed);
        }
        cases++;
    }
    for (unsigned length = 0; length <= 5; length++) {
        reset(); reply(1, 0, length);
        unsigned char output[4] = {0};
        size_t amount = sizeof(output);
        int ret = afk_epic_command(&epic, 1, 0xc0, NULL, 0, output, &amount);
        assert((ret == 0) == (length <= sizeof(output)) && !live);
        if (ret == 0) {
            assert(amount == length && !memcmp(output, command_rx, amount));
            if (length < 4) assert(output[length] == 0);
        }
        cases++;
    }
    for (unsigned mode = 0; mode < 4; mode++) {
        reset();
        u32 status = mode == 1 ? 0xe00002c2 : mode == 2 ? 7 : 0;
        queue(1, TYPE_REPLY, CAT_REPLY, 0xc0, 0, &status, 4);
        size_t size = 0;
        int ret = afk_epic_command(&epic, 1, 0xc0, NULL, 0, NULL, mode == 3 ? &size : NULL);
        assert(ret == (int)status && !epic.command_pending && !live && size == 0);
        cases++;
    }
    reset(); notify(1); reply(1, 0, 0); nested = require_snapshot = true;
    assert(command() == 0 && calls == 1 && sends == 2 && !epic.command_pending && !live);
    assert(!memcmp(command_tx, "command", 7));
    reset(); notify(1); reply(1, 0, 0); callback_error = 7;
    assert(command() == 7 && epic.command_pending && !live);
    reset(); fail_send = true;
    assert(command() < 0 && epic.tx.failed && epic.command_pending && !live);
    reset(); noise = true;
    assert(command() < 0 && epic.command_pending && noise_events > 0 && !live);
    unsigned before = sends;
    assert(command() < 0 && sends == before);
    reset(); epic.command_seq = (u16)-1;
    reply(1, (u16)-1, 0);
    assert(command() == 0 && captured_sequence == (u16)-1 && !epic.command_pending);
    reply(1, (u16)-1, 0); reply(1, 0, 0);
    assert(command() == 0 && captured_sequence == 0 && *epic.rx.rptr == *epic.rx.wptr);
    cases += 6;

    reset(); reply(1, 0, 0);
    afk_epic_ep_t other = {.ep = 0x20, .afk = &afk};
    afk.endpoint[0] = &other;
    afk.endpoint[1] = &epic;
    epic.ep = 0x21;
    noise = true;
    assert(afk_epic_work(&afk, 0x21) == EPIC_DATA_READY && noise_events == 16);
    cases++;

    const size_t sizes[] = {16385, (1ULL << 32), (size_t)-1};
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
        reset();
        unsigned char saved[16]; memcpy(saved, command_tx, sizeof(saved));
        assert(afk_epic_command(&epic, 1, 0xc0, "abc", sizes[i], NULL, NULL) < 0);
        assert(!sends && !epic.command_pending && !memcmp(saved, command_tx, sizeof(saved)));
        size_t amount = sizes[i];
        assert(afk_epic_command(&epic, 1, 0xc0, NULL, 0, saved, &amount) < 0);
        assert(!sends && amount == sizes[i] && !epic.command_pending);
        cases++;
    }
    reset();
    assert(afk_epic_command(&epic, 1, 0xc0, NULL, 1, NULL, NULL) < 0);
    size_t amount = 1;
    assert(afk_epic_command(&epic, 1, 0xc0, NULL, 0, NULL, &amount) < 0);
    epic.txbuf.bfr = NULL;
    assert(command() < 0 && !sends && !epic.command_pending);
    cases += 3;
}

static int parse_properties(void *bytes, size_t size, s64 *unit)
{
    struct dcp_parse_ctx ctx;
    char *name = NULL, *class = NULL;
    int ret = parse(bytes, size, &ctx);
    if (!ret) {
        ret = parse_epic_service_init(&ctx, &name, &class, unit);
        assert(ctx.pos <= ctx.len);
        if (!ret)
            assert(name && class);
        else
            assert(!name && !class);
    }
    test_free(name); test_free(class);
    assert(!live);
    return ret;
}
static void property_cases(void)
{
    unsigned char bytes[512];
    size_t size = properties(bytes, false);
    for (unsigned length = 0; length <= size; length++) {
        reset();
        unsigned char *exact = malloc(length + 1);
        assert(exact);
        memcpy(exact + 1, bytes, length); /* Explicit unaligned input. */
        s64 unit = -1;
        int ret = parse_properties(exact + 1, length, &unit);
        assert((ret == 0) == (length == size));
        assert(unit == (ret ? -1 : 7));
        free(exact);
        cases++;
    }
    for (unsigned fail = 1; fail <= 6; fail++) {
        reset(); fail_allocation = fail;
        s64 unit = -1;
        int ret = parse_properties(bytes, size, &unit);
        assert((ret == 0) == (fail == 6));
        assert(unit == (ret ? -1 : 7));
        cases++;
    }
    for (unsigned depth = 0; depth <= 40; depth++) {
        reset(); size = properties(bytes, false);
        u32 dict = (DCP_TYPE_DICTIONARY << 24) | 4;
        memcpy(bytes + 4, &dict, 4);
        size = put_string(bytes, size, "unknown");
        for (unsigned i = 0; i < depth; i++)
            size = put_tag(bytes, size, DCP_TYPE_ARRAY, 1);
        size = put_tag(bytes, size, DCP_TYPE_BOOL, 1);
        s64 unit = -1;
        int ret = parse_properties(bytes, size, &unit);
        assert((ret == 0) == (depth < 32));
        cases++;
    }
    u32 random = 0x1551cafe;
    for (unsigned iteration = 0; iteration < 4000; iteration++) {
        reset(); size = properties(bytes, false);
        random = random * 1664525 + 1013904223;
        unsigned pos = (random >> 8) % size;
        bytes[pos] ^= random >> 24;
        unsigned length = iteration & 1 ? size : (random >> 16) % (size + 1);
        unsigned char *exact = malloc(length ? length : 1);
        assert(exact);
        memcpy(exact, bytes, length);
        s64 unit = -1;
        (void)parse_properties(exact, length, &unit);
        free(exact);
        cases++;
    }
    reset();
    struct dcp_parse_ctx ctx = {.blob = bytes, .len = 16, .pos = (u32)-1};
    assert(!parse_bytes(&ctx, 1) && !parse_tag(&ctx));
    assert(parse(bytes, (1ULL << 32), &ctx) < 0);
    assert(parse(NULL, 4, &ctx) < 0 && parse(bytes, 4, NULL) < 0);
    cases += 4;
}

static void interface_prepare(void)
{
    reset(); epic.num_channels = 0;
    epic.rxbuf = epic.txbuf = (struct rtkit_buffer){0};
}
static void announce(u32 channel, bool with_properties, bool matched)
{
    unsigned char payload[1024] = {0};
    memcpy(payload, "test", 5);
    size_t size = 32;
    if (with_properties)
        size += properties(payload + 32, false);
    if (!matched)
        for (unsigned i = 0; i + 4 <= size; i++)
            if (!memcmp(payload + i, "test", 4)) memcpy(payload + i, "none", 4);
    queue(channel, TYPE_NOTIFY, CAT_REPORT, SUBTYPE_ANNOUNCE, 0, payload, size);
}
static void interface_cases(void)
{
    for (unsigned props = 0; props < 2; props++) {
        interface_prepare(); announce(1, props, true);
        assert(afk_epic_start_interface(&epic, NULL, 1, 16384, 16384) == 0);
        assert(epic.num_channels == 1 && calls == 1 && rtk_allocs == 2 && !live);
        assert(epic.rxbuf.bfr && epic.txbuf.bfr);
        cases++;
    }
    for (unsigned length = 0; length < 32; length++) {
        interface_prepare();
        unsigned char payload[32] = {0};
        queue(1, TYPE_NOTIFY, CAT_REPORT, SUBTYPE_ANNOUNCE, 0, payload, length);
        assert(afk_epic_start_interface(&epic, NULL, 1, 16384, 16384) < 0);
        assert(!epic.num_channels && !calls && !rtk_allocs && !live && epic.rx.failed);
        cases++;
    }
    interface_prepare(); announce(1, false, true);
    memset(((struct afk_qe *)epic.rx.buf)->data + 40, 'x', 32);
    assert(afk_epic_start_interface(&epic, NULL, 1, 16384, 16384) < 0);
    assert(epic.rx.failed && !calls && !live);
    interface_prepare(); announce(1, true, false);
    assert(afk_epic_start_interface(&epic, NULL, 1, 16384, 16384) < 0);
    assert(!calls && !rtk_allocs && !live);
    interface_prepare(); announce(1, true, true); announce(1, true, true);
    assert(afk_epic_start_interface(&epic, NULL, 2, 16384, 16384) < 0);
    assert(calls == 1 && epic.num_channels == 1 && !rtk_allocs && !live);
    interface_prepare(); announce(1, true, true); announce(2, true, true);
    assert(afk_epic_start_interface(&epic, NULL, 2, 16384, 16384) == 0);
    assert(calls == 2 && epic.num_channels == 2 && rtk_allocs == 2 && !live);
    for (unsigned fail = 1; fail <= 2; fail++) {
        interface_prepare(); announce(1, false, true); fail_rtk_allocation = fail;
        assert(afk_epic_start_interface(&epic, NULL, 1, 16384, 16384) < 0);
        assert(!epic.rxbuf.bfr && !epic.txbuf.bfr && rtk_frees == fail - 1 && !live);
        cases++;
    }
    interface_prepare();
    assert(afk_epic_start_interface(&epic, NULL, 0, 16384, 16384) < 0);
    assert(afk_epic_start_interface(&epic, NULL, 9, 16384, 16384) < 0);
    assert(afk_epic_start_interface(&epic, NULL, 1, 0, 16384) < 0);
    assert(!rtk_allocs && !live);
    cases += 7;
}
#endif

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "envelope")) envelope();
    else if (!strcmp(argv[1], "lifetime")) lifetime();
    else if (!strcmp(argv[1], "notify-channel")) notify_channel();
    else if (!strcmp(argv[1], "reply-channel")) reply_channel();
    else if (!strcmp(argv[1], "reply-sequence")) reply_sequence();
    else if (!strcmp(argv[1], "reply-address")) reply_address();
    else if (!strcmp(argv[1], "skip-truncated")) skip_truncated();
    else if (!strcmp(argv[1], "duplicate-property")) duplicate_property();
    else if (!strcmp(argv[1], "parser-oom")) parser_oom();
    else if (!strcmp(argv[1], "interface-timeout")) interface_timeout();
    else if (!strcmp(argv[1], "parser-unaligned")) parser_unaligned();
    else if (!strcmp(argv[1], "work-noise")) work_noise();
    else if (!strcmp(argv[1], "command-nested")) command_nested();
    else if (!strcmp(argv[1], "all")) {
        envelope(); lifetime(); notify_channel(); reply_channel(); reply_sequence(); reply_address();
        skip_truncated(); duplicate_property(); parser_oom(); interface_timeout();
        parser_unaligned(); work_noise(); command_nested();
#ifndef BASELINE
        message_bounds(); command_cases(); property_cases(); interface_cases();
#endif
    } else assert(0);
    assert(!live);
    printf("PASS: %u EPIC/parser checks; actual AFK and parser C; ASan/UBSan\n", cases);
}
