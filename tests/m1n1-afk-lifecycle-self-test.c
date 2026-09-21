/* SPDX-License-Identifier: MIT */
/* Complete AFK/parser C with fake RTKit and tracked owned allocations. */
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

static void *allocations[128];
static unsigned live, cases, sends, starts, frees, allocations_seen, fail_allocation;
static unsigned fail_free, init_step, shutdown_sends, callbacks;
static bool fail_start, fail_init, fail_shutdown, recv_error, startup_timeout, ack_shutdown;
static bool ack_pending, inject_start_ack, noise, reentrant_send, reentrant_receive;
static bool receive_other_ep;
static int endpoint;
static u64 ticks;
static afk_epic_t *owner;

static bool is_live(void *pointer)
{ for (unsigned i = 0; i < live; i++) if (allocations[i] == pointer) return true; return false; }
static void *test_malloc(size_t size)
{
    if (++allocations_seen == fail_allocation) return NULL;
    assert(size && live < 128);
    void *pointer = malloc(size); assert(pointer); allocations[live++] = pointer; return pointer;
}
static void *test_calloc(size_t count, size_t size)
{ void *p = test_malloc(count * size); if (p) memset(p, 0, count * size); return p; }
static void test_free(void *pointer)
{
    if (!pointer) return;
    unsigned i = 0; while (i < live && allocations[i] != pointer) i++;
    assert(i < live); allocations[i] = allocations[--live]; free(pointer);
}
int debug_printf(const char *fmt, ...) { (void)fmt; return 0; }
void hexdump(const void *data, size_t size) { (void)data; (void)size; }
u64 timeout_calculate(u32 usec) { return ticks + usec; }
bool timeout_expired(u64 deadline) { ticks += 10000; return ticks >= deadline; }
bool rtkit_start_ep(rtkit_dev_t *rtk, u8 ep)
{ assert(rtk == (void *)1); starts++; endpoint = ep; return !fail_start; }
bool rtkit_send(rtkit_dev_t *rtk, const struct rtkit_message *msg)
{
    assert(rtk == (void *)1); sends++;
    unsigned type = FIELD_GET(RBEP_TYPE, msg->msg);
#ifndef BASELINE
    if (type == RBEP_SEND && reentrant_send) {
        afk_epic_ep_t *ep = owner->endpoint[0];
        assert(ep->active_calls && afk_epic_shutdown_ep(ep) < 0 && is_live(ep));
        callbacks++;
    }
#endif
    if (type == RBEP_INIT) { if (fail_init) return false; init_step = 1; }
    if (type == RBEP_SHUTDOWN) {
        shutdown_sends++; if (fail_shutdown) return false;
        if (ack_shutdown) { ack_pending = true; endpoint = msg->ep; }
    }
    return true;
}
int rtkit_recv(rtkit_dev_t *rtk, struct rtkit_message *msg)
{
    assert(rtk == (void *)1);
#ifndef BASELINE
    if (reentrant_receive) {
        reentrant_receive = false;
        afk_epic_ep_t *ep = owner->endpoint[0];
        assert(ep && ep->active_calls && afk_epic_shutdown_ep(ep) < 0 && is_live(ep));
        callbacks++;
    }
#endif
    if (recv_error) return -1;
    *msg = (struct rtkit_message){.ep = endpoint};
    if (receive_other_ep) {
        receive_other_ep = false;
        *msg = (struct rtkit_message){.ep = 0x21, .msg = FIELD_PREP(RBEP_TYPE, RBEP_RECV)};
        return 1;
    }
    if (ack_pending) { ack_pending = false; msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_SHUTDOWN_ACK); return 1; }
    if (inject_start_ack) { inject_start_ack = false; msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_START_ACK); return 1; }
    if (startup_timeout) return 0;
    switch (init_step++) {
        case 1: msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_GETBUF) | FIELD_PREP(GETBUF_SIZE, 128) | 7; return 1;
        case 2: msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_INIT_RX) | FIELD_PREP(INITRB_SIZE, 35) | 7; return 1;
        case 3: msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_INIT_TX) | FIELD_PREP(INITRB_SIZE, 35) |
                            FIELD_PREP(INITRB_OFFSET, 64) | 7; return 1;
        case 4: msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_START_ACK); return 1;
        default: init_step = 5; break;
    }
    if (noise) { msg->msg = FIELD_PREP(RBEP_TYPE, RBEP_RECV); return 1; }
    return 0;
}
bool rtkit_can_recv(rtkit_dev_t *rtk)
{ assert(rtk == (void *)1); return ack_pending || inject_start_ack || noise || reentrant_receive || receive_other_ep; }
bool rtkit_alloc_buffer(rtkit_dev_t *rtk, struct rtkit_buffer *buffer, size_t size)
{
    assert(rtk == (void *)1 && !buffer->bfr && size <= 8192);
    void *pointer = test_calloc(1, size); if (!pointer) return false;
    *buffer = (struct rtkit_buffer){.bfr = pointer, .sz = size, .dva = 1ULL << 40, .owned = true};
    if (size == 8192) { *(u32 *)pointer = 2048; *(u32 *)(pointer + 4096) = 2048; }
    return true;
}
bool rtkit_free_buffer(rtkit_dev_t *rtk, struct rtkit_buffer *buffer)
{
    assert(rtk == (void *)1);
    if (!buffer->bfr) return true;
    if (++frees == fail_free) return false;
    test_free(buffer->bfr); *buffer = (struct rtkit_buffer){0}; return true;
}
#ifndef BASELINE
static void callback(afk_epic_ep_t *epic) { (void)epic; callbacks++; }
static int shutdown_callback(afk_epic_service_t *service, u32 index, const void *data,
                             size_t size, void *reply, size_t reply_size)
{
    (void)index; (void)data; (void)size; (void)reply; (void)reply_size;
    assert(service->epic->active_calls && afk_epic_shutdown_ep(service->epic) < 0);
    assert(afk_epic_shutdown(owner) < 0 && is_live(owner) && is_live(service->epic));
    callbacks++; return 0;
}
static int cross_endpoint_callback(afk_epic_service_t *service, u32 index, const void *data,
                                   size_t size, void *reply, size_t reply_size)
{
    (void)index; (void)data; (void)size; (void)reply; (void)reply_size;
    afk_epic_ep_t *target = owner->endpoint[0];
    assert(target && service->epic == owner->endpoint[1] && service->epic != target);
    void *buffer = target->buf.bfr;
    assert(target->active_calls && afk_epic_shutdown_ep(target) < 0);
    assert(is_live(target) && target->buf.bfr == buffer && (!buffer || is_live(buffer)));
    callbacks++; return 0;
}
static void queue_other_endpoint(afk_epic_ep_t *other)
{
    static const afk_epic_service_ops_t ops = {.name = "cross-shutdown", .call = cross_endpoint_callback};
    assert(other == owner->endpoint[1]);
    other->recv_handler = afk_epic_notify_handler;
    other->services[0] = (afk_epic_service_t){.epic = other, .channel = 1, .enabled = true, .ops = &ops};
    other->num_channels = 1;
    struct afk_qe *qe = other->rx.buf;
    struct epic_hdr *header = (void *)qe->data;
    struct epic_sub_hdr *sub = (void *)(header + 1);
    struct epic_std_service_ap_call *call = (void *)(sub + 1);
    *qe = (struct afk_qe){.magic = QE_MAGIC,
        .size = sizeof(*header) + sizeof(*sub) + sizeof(*call), .channel = 1, .type = TYPE_NOTIFY};
    *header = (struct epic_hdr){.version = 2};
    *sub = (struct epic_sub_hdr){.version = 4, .category = CAT_NOTIFY,
        .type = SUBTYPE_STD_SERVICE, .length = sizeof(*call)};
    *call = (struct epic_std_service_ap_call){.type = 1};
    *other->rx.wptr = ALIGN_UP(sizeof(*qe) + qe->size, other->rx.block_size);
    receive_other_ep = true;
}
#endif
static void reset(void)
{
    assert(!live);
    sends = starts = frees = allocations_seen = fail_allocation = fail_free = 0;
    init_step = shutdown_sends = callbacks = 0; ticks = 0; endpoint = 0x20;
    fail_start = fail_init = fail_shutdown = recv_error = startup_timeout = false;
    ack_pending = inject_start_ack = noise = reentrant_send = reentrant_receive = receive_other_ep = false;
    ack_shutdown = true;
    owner = afk_epic_init((void *)1); assert(owner);
}
static afk_epic_ep_t *start(void)
{ afk_epic_ep_t *ep = afk_epic_start_ep(owner, 0x20, NULL, false); assert(ep && ep->started); return ep; }
static void finish(void)
{
    recv_error = fail_shutdown = startup_timeout = noise = false; fail_free = 0; ack_shutdown = true;
    /* A pending request gets a late ACK without sending the request again. */
    if (owner->endpoint[0]) { endpoint = 0x20; ack_pending = true; }
    assert(afk_epic_shutdown(owner) == 0 && !live);
}
static void range(void)
{ reset(); assert(!afk_epic_start_ep(owner, 0x100, NULL, false) && !starts); finish(); cases++; }
static void duplicate(void)
{ reset(); afk_epic_ep_t *ep = start(); assert(!afk_epic_start_ep(owner, 0x20, NULL, false));
  assert(owner->endpoint[0] == ep && starts == 1); finish(); cases++; }
static void start_error(void)
{ reset(); recv_error = true; assert(!afk_epic_start_ep(owner, 0x20, NULL, false));
  assert(owner->endpoint[0] && is_live(owner->endpoint[0])); finish(); cases++; }
static void start_timeout(void)
{ reset(); startup_timeout = true; assert(!afk_epic_start_ep(owner, 0x20, NULL, false));
  assert(!owner->endpoint[0] && shutdown_sends == 1); finish(); cases++; }
static void shutdown_error(void)
{ reset(); afk_epic_ep_t *ep = start(); recv_error = true;
  assert(afk_epic_shutdown_ep(ep) < 0 && owner->endpoint[0] == ep && is_live(ep) && !frees);
  finish(); cases++; }
static void shutdown_timeout(void)
{ reset(); afk_epic_ep_t *ep = start(); ack_shutdown = false;
  assert(afk_epic_shutdown_ep(ep) < 0 && owner->endpoint[0] == ep && is_live(ep) && !frees);
  finish(); cases++; }
static void unsolicited_ack(void)
{ reset(); afk_epic_ep_t *ep = start(); ack_pending = true;
  assert(afk_epic_poll(owner, 0x20, false) < 0 && ep->started); finish(); cases++; }
static void free_failure(void)
{ reset(); afk_epic_ep_t *ep = start(); fail_free = 1;
  assert(afk_epic_shutdown_ep(ep) < 0 && owner->endpoint[0] == ep && is_live(ep->buf.bfr));
  finish(); cases++; }
static void parent_failure(void)
{ reset(); start(); fail_shutdown = true;
  assert(afk_epic_shutdown(owner) < 0 && is_live(owner) && owner->endpoint[0]);
  finish(); cases++; }
int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "range")) range();
    else if (!strcmp(argv[1], "duplicate")) duplicate();
    else if (!strcmp(argv[1], "start-error")) start_error();
    else if (!strcmp(argv[1], "start-timeout")) start_timeout();
    else if (!strcmp(argv[1], "shutdown-error")) shutdown_error();
    else if (!strcmp(argv[1], "shutdown-timeout")) shutdown_timeout();
    else if (!strcmp(argv[1], "unsolicited-ack")) unsolicited_ack();
    else if (!strcmp(argv[1], "free-failure")) free_failure();
    else if (!strcmp(argv[1], "parent-failure")) parent_failure();
    else {
        assert(!strcmp(argv[1], "all"));
        range(); duplicate(); start_error(); start_timeout(); shutdown_error();
        shutdown_timeout(); unsolicited_ack(); free_failure(); parent_failure();
#ifndef BASELINE
        for (int number = -32; number < 64; number++) {
            if (number >= 0x20 && number < 0x30) continue;
            reset(); assert(!afk_epic_start_ep(owner, number, NULL, false) && !starts);
            finish(); cases++;
        }
        for (int number = 0x20; number < 0x30; number++) {
            reset(); afk_epic_ep_t *current = afk_epic_start_ep(owner, number, NULL, false);
            assert(current && current->started && !current->active_calls);
            finish(); cases++;
        }
        for (unsigned allocation = 1; allocation <= 2; allocation++) {
            reset(); fail_allocation = allocations_seen + allocation;
            assert(!afk_epic_start_ep(owner, 0x20, NULL, false) && !owner->endpoint[0]);
            finish(); cases++;
        }
        for (unsigned which = 1; which <= 3; which++) {
            reset(); afk_epic_ep_t *ep = start();
            assert(rtkit_alloc_buffer((void *)1, &ep->rxbuf, 32));
            assert(rtkit_alloc_buffer((void *)1, &ep->txbuf, 32));
            fail_free = which;
            assert(afk_epic_shutdown_ep(ep) < 0 && is_live(ep) && ep->shutdown_acked);
            assert(shutdown_sends == 1);
            fail_free = 0; assert(!afk_epic_shutdown_ep(ep));
            assert(!owner->endpoint[0] && shutdown_sends == 1); finish(); cases++;
        }
        reset(); fail_start = true;
        assert(!afk_epic_start_ep(owner, 0x20, NULL, false) && !owner->endpoint[0] && !sends);
        finish(); cases++;
        reset(); fail_init = true;
        assert(!afk_epic_start_ep(owner, 0x20, NULL, false) && !owner->endpoint[0] && shutdown_sends == 1);
        finish(); cases++;
        reset(); fail_init = fail_shutdown = true;
        assert(!afk_epic_start_ep(owner, 0x20, NULL, false) && owner->endpoint[0]->stopping);
        finish(); cases++;
        for (unsigned mode = 0; mode < 3; mode++) {
            reset(); afk_epic_ep_t *ep = start(); ep->recv_handler = callback;
            if (mode == 0) fail_shutdown = true;
            if (mode == 1) recv_error = true;
            if (mode == 2) ack_shutdown = false;
            assert(afk_epic_shutdown_ep(ep) < 0 && ep->stopping);
            recv_error = false; ack_pending = false; noise = true;
            assert(afk_epic_work(owner, 0x20) < 0);
            assert(afk_epic_command(ep, 0, 0xc0, NULL, 0, NULL, NULL) < 0);
            assert(afk_epic_start_interface(ep, NULL, 1, 32, 32) < 0);
            for (unsigned i = 0; i < 32; i++) assert(afk_epic_poll(owner, -1, false) == 0);
            inject_start_ack = true; assert(!afk_epic_poll(owner, -1, false));
            assert(!callbacks && !frees); finish(); cases++;
        }
        reset(); afk_epic_ep_t *ep = start(); ack_shutdown = false;
        assert(afk_epic_shutdown(owner) < 0 && owner->stopping && ep->stopping);
        assert(!afk_epic_start_ep(owner, 0x21, NULL, false) && afk_epic_work(owner, -1) < 0);
        finish(); cases++;
        assert(!afk_epic_shutdown(NULL) && !afk_epic_shutdown_ep(NULL)); cases++;
        reset(); ep = start();
        static const afk_epic_service_ops_t ops = {.name = "shutdown", .call = shutdown_callback};
        ep->services[0] = (afk_epic_service_t){.enabled = true, .epic = ep, .channel = 1, .ops = &ops};
        ep->num_channels = 1;
        struct epic_std_service_ap_call call = {.type = 1, .len = 0};
        assert(!afk_epic_handle_std_service(ep, 1, CAT_NOTIFY, 0, &call, sizeof(call)));
        assert(callbacks == 1 && !ep->active_calls && !frees && !shutdown_sends); finish(); cases++;
        reset(); ep = start();
        assert(rtkit_alloc_buffer((void *)1, &ep->rxbuf, 32));
        assert(rtkit_alloc_buffer((void *)1, &ep->txbuf, 32)); reentrant_send = true;
        assert(afk_epic_command(ep, 0, 0xc0, NULL, 0, NULL, NULL) < 0);
        assert(callbacks == 1 && !ep->active_calls && ep->command_pending && !shutdown_sends);
        finish(); cases++;
        reset(); reentrant_receive = true; ep = start();
        assert(callbacks == 1 && !ep->active_calls && !shutdown_sends); finish(); cases++;
        reset(); ep = start(); reentrant_receive = true;
        assert(afk_epic_start_interface(ep, NULL, 1, 32, 32) < 0);
        assert(callbacks == 1 && !ep->active_calls && !shutdown_sends); finish(); cases++;
        reset(); ep = start(); reentrant_receive = true;
        assert(!afk_epic_shutdown_ep(ep) && callbacks == 1 && !owner->endpoint[0]);
        finish(); cases++;
        for (unsigned operation = 0; operation < 3; operation++) {
            reset();
            afk_epic_ep_t *other = afk_epic_start_ep(owner, 0x21, NULL, false);
            assert(other && other->started);
            if (operation == 0) {
                queue_other_endpoint(other); ep = start(); assert(ep->started);
            } else {
                ep = start(); queue_other_endpoint(other);
                if (operation == 1) assert(afk_epic_start_interface(ep, NULL, 1, 32, 32) < 0);
                else assert(!afk_epic_shutdown_ep(ep));
            }
            assert(callbacks == 1 && is_live(other));
            if (operation < 2) assert(is_live(ep) && !ep->active_calls);
            else assert(!owner->endpoint[0]);
            finish(); cases++;
        }
#endif
    }
    printf("AFK lifecycle actual C: PASS (%u checks)\n", cases);
    return 0;
}
