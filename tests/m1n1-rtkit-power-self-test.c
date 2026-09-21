/* SPDX-License-Identifier: MIT */
/* Complete RTKit implementation. Only fake ASC, time, and owned test memory. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rtkit.h"
#include "utils.h"

static void *test_memalign(size_t alignment, size_t size);
static void test_free(void *pointer);
#define memalign test_memalign
#define free test_free
#include M1N1_RTKIT_SOURCE
#undef memalign
#undef free
#undef printf

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static unsigned checks, sends, receives, stops, fail_send, phase;
static unsigned delays[3], flood, flood_left;
static bool acknowledge[3], wrong[3], crash[3], early_iop;
static bool queued;
static bool stale_tail, flood_after_send;
static unsigned script_pos, script_len;
static unsigned post_ack_message;
static struct asc_message script[32];
static struct asc_message incoming;
static u64 ticks;
static enum rtkit_power_state target;
static struct crashlog_hdr crash_header = {.type = 'BAD!'};
static unsigned char retained[32];
static rtkit_dev_t device;

int debug_printf(const char *fmt, ...) { (void)fmt; return 0; }
u64 timeout_calculate(u32 usec) { return ticks + usec; }
bool timeout_expired(u64 deadline) { ticks += 10000; return ticks >= deadline; }

/* Any cleanup or DMA mapping during a power handshake is a test failure. */
static void *test_memalign(size_t alignment, size_t size)
{ (void)alignment; (void)size; assert(!"unexpected allocation"); return NULL; }
static void test_free(void *pointer) { (void)pointer; assert(!"unexpected free"); }
bool is_heap(void *pointer) { (void)pointer; return false; }
u64 iova_alloc(iova_domain_t *domain, size_t size)
{ (void)domain; (void)size; assert(!"unexpected IOVA allocation"); return 0; }
void iova_free(iova_domain_t *domain, u64 dva, size_t size)
{ (void)domain; (void)dva; (void)size; assert(!"unexpected IOVA free"); }
int dart_map(dart_dev_t *dart, uintptr_t dva, void *pointer, size_t size)
{ (void)dart; (void)dva; (void)pointer; (void)size; assert(!"unexpected map"); return -1; }
#ifdef DART_LIFECYCLE
bool dart_unmap(dart_dev_t *dart, uintptr_t dva, size_t size)
{ (void)dart; (void)dva; (void)size; assert(!"unexpected unmap"); return false; }
#else
void dart_unmap(dart_dev_t *dart, uintptr_t dva, size_t size)
{ (void)dart; (void)dva; (void)size; assert(!"unexpected unmap"); }
#endif
void *dart_translate(dart_dev_t *dart, uintptr_t dva)
{ (void)dart; (void)dva; assert(!"unexpected translation"); return NULL; }
bool sart_add_allowed_region(sart_dev_t *sart, void *pointer, size_t size)
{ (void)sart; (void)pointer; (void)size; assert(!"unexpected SART map"); return false; }
bool sart_remove_allowed_region(sart_dev_t *sart, void *pointer, size_t size)
{ (void)sart; (void)pointer; (void)size; assert(!"unexpected SART unmap"); return false; }

static struct asc_message ack(bool ap, u32 state)
{
    return (struct asc_message){.msg1 = RTKIT_EP_MGMT,
        .msg0 = FIELD_PREP(MGMT_TYPE, ap ? MGMT_MSG_AP_PWR_STATE_ACK : MGMT_MSG_IOP_PWR_STATE_ACK) |
                FIELD_PREP(MGMT_PWR_STATE, state)};
}
bool asc_send(asc_dev_t *asc, const struct asc_message *message)
{
    assert(asc == (void *)1);
    sends++;
    if (sends == fail_send)
        return false;
    assert(message->msg1 == RTKIT_EP_MGMT);
    unsigned type = FIELD_GET(MGMT_TYPE, message->msg0);
    unsigned state = FIELD_GET(MGMT_PWR_STATE, message->msg0);
    if (type == MGMT_MSG_AP_PWR_STATE) {
        assert(state == RTKIT_POWER_QUIESCED);
        phase = 1;
        if (early_iop) {
            incoming = ack(false, target);
            queued = true;
        }
        if (stale_tail) {
            script_len = 17;
            memset(script, 0, sizeof(script));
            script[15] = ack(true, RTKIT_POWER_QUIESCED);
            script[16] = ack(false, target);
            acknowledge[1] = acknowledge[2] = false;
        }
    } else {
        assert(type == MGMT_MSG_IOP_PWR_STATE && state == target);
        assert(device.ap_power == RTKIT_POWER_QUIESCED);
        phase = 2;
        if (post_ack_message) {
            script_pos = 0; script_len = 17;
            memset(script, 0, sizeof(script));
            script[15] = ack(false, target);
            if (post_ack_message == 1)
                script[16] = ack(true, RTKIT_POWER_ON);
            else if (post_ack_message == 2)
                script[16] = ack(false, RTKIT_POWER_ON);
            else
                script[16] = (struct asc_message){.msg1 = RTKIT_EP_CRASHLOG,
                    .msg0 = FIELD_PREP(MGMT_TYPE, MSG_BUFFER_REQUEST)};
            acknowledge[2] = false;
        }
    }
    return true;
}
bool asc_recv(asc_dev_t *asc, struct asc_message *message)
{
    assert(asc == (void *)1);
    receives++;
    if (script_pos < script_len) {
        *message = script[script_pos++];
        return true;
    }
    if (queued) {
        *message = incoming;
        queued = false;
        return true;
    }
    if (flood && flood_left && (!flood_after_send || phase)) {
        if (flood_left != (unsigned)-1)
            flood_left--;
        /* Invalid endpoint, harmless system message, or application message. */
        *message = (struct asc_message){.msg1 = flood == 1 ? 0x100 : flood == 2 ? 0 : 0x20,
                                       .msg0 = 0};
        return true;
    }
    if (!phase)
        return false;
    if (delays[phase]) {
        delays[phase]--;
        return false;
    }
    if (crash[phase]) {
        crash[phase] = false;
        *message = (struct asc_message){.msg1 = RTKIT_EP_CRASHLOG,
            .msg0 = FIELD_PREP(MGMT_TYPE, MSG_BUFFER_REQUEST)};
        return true;
    }
    if (wrong[phase]) {
        wrong[phase] = false;
        *message = ack(phase == 1, RTKIT_POWER_ON);
        return true;
    }
    if (acknowledge[phase]) {
        acknowledge[phase] = false;
        *message = ack(phase == 1, phase == 1 ? RTKIT_POWER_QUIESCED : target);
        return true;
    }
    return false;
}
bool asc_can_recv(asc_dev_t *asc)
{
    assert(asc == (void *)1);
    return queued || (flood && flood_left && (!flood_after_send || phase)) || script_pos < script_len;
}
void asc_cpu_stop(asc_dev_t *asc)
{
    assert(asc == (void *)1 && device.ap_power == RTKIT_POWER_QUIESCED &&
           device.iop_power == RTKIT_POWER_SLEEP && !device.crashed);
    stops++;
}

static void reset(void)
{
    sends = receives = stops = fail_send = phase = flood = flood_left = 0;
    ticks = 0;
    queued = early_iop = stale_tail = flood_after_send = false;
    script_pos = script_len = post_ack_message = 0;
    memset(delays, 0, sizeof(delays));
    memset(wrong, 0, sizeof(wrong));
    memset(crash, 0, sizeof(crash));
    acknowledge[1] = acknowledge[2] = true;
    target = RTKIT_POWER_SLEEP;
    memset(retained, 0xa5, sizeof(retained));
    device = (rtkit_dev_t){.asc = (void *)1, .name = "power-test",
        .ap_power = RTKIT_POWER_ON, .iop_power = RTKIT_POWER_ON,
        .syslog_bfr = {.bfr = retained, .dva = 1ULL << 40, .sz = sizeof(retained), .owned = true},
        .crashlog_bfr = {.bfr = &crash_header, .sz = sizeof(crash_header)}};
}
static void retained_unchanged(void)
{
    assert(device.syslog_bfr.bfr == retained && device.syslog_bfr.owned &&
           device.syslog_bfr.dva == 1ULL << 40 && device.syslog_bfr.sz == sizeof(retained));
    for (unsigned i = 0; i < sizeof(retained); i++)
        assert(retained[i] == 0xa5);
}
static void sleep_success(void)
{
    reset();
    assert(rtkit_sleep(&device));
    assert(sends == 2 && receives >= 2 && stops == 1);
    retained_unchanged(); checks++;
}
static void sleep_send_failure(void)
{
    reset(); fail_send = 1;
    assert(!rtkit_sleep(&device));
    assert(sends == 1 && !receives && !stops);
    retained_unchanged(); checks++;
}
static void crashed_sleep(void)
{
    reset(); device.crashed = true;
    assert(!rtkit_sleep(&device));
    assert(!sends && !receives && !stops);
    retained_unchanged(); checks++;
}
static void timeout_phase(unsigned missing)
{
    reset(); acknowledge[missing] = false;
    assert(!rtkit_sleep(&device));
    assert(sends == missing && !stops && ticks <= 2200000);
    retained_unchanged(); checks++;
}
static void stale_cache(void)
{
    reset(); device.ap_power = RTKIT_POWER_QUIESCED; device.iop_power = target;
    acknowledge[1] = acknowledge[2] = false;
    assert(!rtkit_sleep(&device));
    assert(sends == 1 && receives > 0 && !stops);
    retained_unchanged(); checks++;
}
static void endless_flood(unsigned type)
{
    reset(); flood = type; flood_left = (unsigned)-1; flood_after_send = true;
    assert(!rtkit_sleep(&device));
    assert(sends == 1 && !stops && receives <= 1600 && ticks <= 1100000);
    retained_unchanged(); checks++;
}
static void early_ack(void)
{
    reset(); early_iop = true; acknowledge[2] = false;
    assert(!rtkit_sleep(&device));
    assert(sends == 2 && !stops);
    retained_unchanged(); checks++;
}
static void stale_tail_ack(void)
{
    reset(); stale_tail = true;
    assert(!rtkit_sleep(&device));
    assert(sends == 2 && !stops && script_pos == 17);
    retained_unchanged(); checks++;
}

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "sleep-success")) sleep_success();
    else if (!strcmp(argv[1], "sleep-send-failure")) sleep_send_failure();
    else if (!strcmp(argv[1], "crashed-sleep")) crashed_sleep();
    else if (!strcmp(argv[1], "ap-timeout")) timeout_phase(1);
    else if (!strcmp(argv[1], "iop-timeout")) timeout_phase(2);
    else if (!strcmp(argv[1], "stale-cache")) stale_cache();
    else if (!strcmp(argv[1], "system-flood")) endless_flood(2);
    else if (!strcmp(argv[1], "invalid-flood")) endless_flood(1);
    else if (!strcmp(argv[1], "early-iop")) early_ack();
    else if (!strcmp(argv[1], "stale-tail")) stale_tail_ack();
    else {
        assert(!strcmp(argv[1], "all"));
        sleep_success(); sleep_send_failure(); crashed_sleep();
        timeout_phase(1); timeout_phase(2); stale_cache(); early_ack(); stale_tail_ack();
        for (unsigned type = 1; type <= 3; type++) endless_flood(type);
#ifndef BASELINE
        /* Already queued traffic must be drained before the first request too. */
        reset(); script_len = 17; memset(script, 0, sizeof(script));
        script[15] = ack(true, RTKIT_POWER_QUIESCED); script[16] = ack(false, target);
        acknowledge[1] = acknowledge[2] = false;
        assert(!rtkit_sleep(&device) && script_pos == 17 && sends == 1 && !stops);
        retained_unchanged(); checks++;
        for (unsigned type = 1; type <= 3; type++) {
            reset(); flood = type; flood_left = (unsigned)-1;
            assert(!rtkit_sleep(&device) && !sends && !stops && !device.power_uncertain);
            assert(ticks <= 1100000 && receives <= 1600);
            flood = 0;
            assert(rtkit_sleep(&device) && sends == 2 && stops == 1);
            retained_unchanged(); checks++;
        }
        /* A bad state/crash queued after the final ACK must not be hidden by the budget. */
        for (unsigned type = 1; type <= 3; type++) {
            reset(); post_ack_message = type;
            assert(!rtkit_sleep(&device) && sends == 2 && !stops && device.power_uncertain);
            assert(script_pos == 17);
            retained_unchanged(); checks++;
        }
        /* Both targets, same-state requests, delayed ACKs and wrong-then-correct ACKs. */
        for (unsigned sleep = 0; sleep < 2; sleep++)
            for (unsigned cached = 0; cached < 2; cached++)
                for (unsigned delay = 0; delay < 50; delay++) {
                    reset(); target = sleep ? RTKIT_POWER_SLEEP : RTKIT_POWER_QUIESCED;
                    if (cached) { device.ap_power = RTKIT_POWER_QUIESCED; device.iop_power = target; }
                    delays[1] = delay; delays[2] = 49 - delay;
                    wrong[1] = wrong[2] = true;
                    assert(sleep ? rtkit_sleep(&device) : rtkit_quiesce(&device));
                    assert(sends == 2 && stops == sleep && receives >= 4);
                    assert(!device.power_uncertain);
                    retained_unchanged(); checks++;
                }
        /* First send failure is unpublished and may be retried. */
        reset(); fail_send = 1;
        assert(!rtkit_sleep(&device) && !device.power_uncertain && !stops);
        fail_send = 0;
        assert(rtkit_sleep(&device) && sends == 3 && stops == 1);
        retained_unchanged(); checks++;
        /* An ambiguous phase cannot be retried, even if a late ACK is queued. */
        for (unsigned failure = 0; failure < 5; failure++) {
            reset();
            if (failure == 0) fail_send = 2;
            if (failure == 1 || failure == 2) acknowledge[failure] = false;
            if (failure == 3 || failure == 4) crash[failure - 2] = true;
            assert(!rtkit_sleep(&device) && device.power_uncertain && !stops);
            unsigned before = sends, read_before = receives;
            incoming = ack(false, target); queued = true;
            assert(!rtkit_sleep(&device) && !rtkit_quiesce(&device));
            assert(sends == before && receives == read_before && queued && !stops);
            retained_unchanged(); checks++;
        }
        /* ACK counters wrap without confusing fresh progress with cached state. */
        reset(); device.ap_power_acks = device.iop_power_acks = (u32)-1;
        assert(rtkit_sleep(&device) && device.ap_power_acks == 0 && device.iop_power_acks == 0);
        retained_unchanged(); checks++;
        /* Receive budgets preserve excess traffic for the next call. */
        for (unsigned type = 1; type <= 2; type++)
            for (unsigned count = 1; count <= 65; count++) {
                reset(); flood = type; flood_left = count;
                struct rtkit_message msg;
                unsigned processed = 0;
                while (flood_left) {
                    unsigned before = flood_left, reads = receives;
                    assert(rtkit_recv(&device, &msg) == 0);
                    assert(before - flood_left <= 16 && receives - reads <= 16);
                    processed += before - flood_left;
                }
                assert(processed == count);
                retained_unchanged(); checks++;
            }
        /* Application packets remain one-per-call, untouched and in order. */
        reset(); flood = 3; flood_left = 65;
        for (unsigned count = 0; count < 65; count++) {
            struct rtkit_message msg;
            assert(rtkit_recv(&device, &msg) == 1 && msg.ep == 0x20 && !msg.msg);
            assert(flood_left == 64 - count);
            checks++;
        }
#endif
    }
    printf("RTKit power/receive actual C self-test: PASS (%u checks)\n", checks);
    return 0;
}
