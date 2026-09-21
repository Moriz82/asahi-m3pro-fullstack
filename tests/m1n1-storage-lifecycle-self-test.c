/* SPDX-License-Identifier: MIT */
/* Actual production C; all registers, RTKit, time and allocations are test-owned. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "adt.h"
#include "smc.h"
#include "nvme.h"
#include "pmgr.h"
#include "utils.h"

static void *test_calloc(size_t n, size_t size);
static void *test_memalign(size_t alignment, size_t size);
static void test_free(void *pointer);
static u32 test_read32(u64 address) __attribute__((unused));
static void test_write32(u64 address, u32 value) __attribute__((unused));
static void test_write64(u64 address, u64 value) __attribute__((unused));
static int test_poll32(u64 address, u32 mask, u32 target, u32 timeout) __attribute__((unused));
#define calloc test_calloc
#define memalign test_memalign
#define free test_free
#define read32 test_read32
#define write32 test_write32
#define write64_lo_hi test_write64
#define set32(a, b) test_write32((a), test_read32(a) | (b))
#define clear32(a, b) test_write32((a), test_read32(a) & ~(b))
#define mask32(a, m, b) test_write32((a), (test_read32(a) & ~(m)) | (b))
#define poll32 test_poll32
#include M1N1_STORAGE_SOURCE
#undef calloc
#undef memalign
#undef free
#undef read32
#undef write32
#undef write64_lo_hi
#undef set32
#undef clear32
#undef mask32
#undef poll32
#undef printf
#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static void *allocations[32];
static unsigned live, allocations_seen, fail_allocation, frees, power_calls;
static u64 ticks;
static bool fail_boot, fail_power, fail_free, fail_start, fail_send, fail_receive;
static bool fail_asc, fail_sart, fail_rtkit;
#ifdef SART_LIFECYCLE
static bool fail_sart_release;
#endif
#ifndef BASELINE
static unsigned checks;
/* End a test-owned hardware epoch only after checking quarantined ownership.
 * This is not a production force-free or a claim that hardware can be reset. */
static void end_fake_epoch(void)
{
    while (live) test_free(allocations[live - 1]);
    allocations_seen = fail_allocation = frees = power_calls = 0;
    ticks = 0;
    fail_boot = fail_power = fail_free = fail_start = fail_send = fail_receive = false;
    fail_asc = fail_sart = fail_rtkit = false;
#ifdef SART_LIFECYCLE
    fail_sart_release = false;
#endif
}
#endif

static bool is_live(void *p)
{ for (unsigned i = 0; i < live; ++i) if (allocations[i] == p) return true; return false; }
static void *test_memalign(size_t alignment, size_t size)
{
    if (++allocations_seen == fail_allocation) return NULL;
    void *p = NULL; assert(!posix_memalign(&p, alignment, size)); assert(p && live < 32);
    allocations[live++] = p; memset(p, 0, size); return p;
}
static void *test_calloc(size_t n, size_t size)
{ return test_memalign(16, n * size); }
static void test_free(void *p)
{
    if (!p) return;
    unsigned i = 0; while (i < live && allocations[i] != p) i++;
    assert(i < live); allocations[i] = allocations[--live]; frees++; free(p);
}
int debug_printf(const char *format, ...) { (void)format; return 0; }
u64 timeout_calculate(u32 usec) { return ticks + usec; }
bool timeout_expired(u64 deadline) { ticks += 10000; return ticks >= deadline; }
asc_dev_t *asc_init(const char *path)
{ (void)path; return fail_asc ? NULL : test_calloc(1, 16); }
void asc_free(asc_dev_t *asc) { test_free(asc); }
bool asc_cpu_running(asc_dev_t *asc) { assert(is_live(asc)); return true; }
sart_dev_t *sart_init(const char *path)
{ (void)path; return fail_sart ? NULL : test_calloc(1, 16); }
#ifdef SART_LIFECYCLE
bool sart_free(sart_dev_t *sart)
{ if (sart && fail_sart_release) return false; test_free(sart); return true; }
#else
void sart_free(sart_dev_t *sart) { test_free(sart); }
#endif
rtkit_dev_t *rtkit_init(const char *name, asc_dev_t *asc, dart_dev_t *dart,
                      iova_domain_t *domain, sart_dev_t *sart, bool sram)
{
    (void)name; (void)dart; (void)domain; (void)sart; (void)sram;
    assert(is_live(asc)); return fail_rtkit ? NULL : test_calloc(1, 16);
}
bool rtkit_boot(rtkit_dev_t *rtkit) { assert(is_live(rtkit)); return !fail_boot; }
bool rtkit_sleep(rtkit_dev_t *rtkit)
{ assert(is_live(rtkit)); power_calls++; return !fail_power; }
bool rtkit_quiesce(rtkit_dev_t *rtkit) { return rtkit_sleep(rtkit); }
bool rtkit_free(rtkit_dev_t *rtkit)
{ if (!rtkit) return true; assert(is_live(rtkit)); if (fail_free) return false; test_free(rtkit); return true; }
bool rtkit_start_ep(rtkit_dev_t *rtkit, u8 ep)
{ assert(is_live(rtkit) && ep == 0x20); return !fail_start; }

#ifdef TEST_NVME
#define BASE 0x100000
static u32 registers[0x30000 / 4];
static unsigned submissions, invalidations, reset_calls, drop_submission, address_writes;
static bool fail_stop, fail_disable, fail_enable, drop_completion, bad_tag, bad_invalidation, completion_error;
static void *last_dma;
static int reset_result[2];
static bool reenter_shutdown __attribute__((unused));
void *adt;
int adt_path_offset_trace(const void *tree, const char *path, int *trace)
{ (void)tree; (void)path; trace[0] = 1; return 1; }
const void *adt_getprop(const void *tree, int node, const char *name, u32 *size)
{ (void)tree; (void)node; (void)name; if (size) *size = 0; return NULL; }
const struct adt_property *adt_get_property(const void *tree, int node, const char *name)
{ (void)tree; (void)node; (void)name; return NULL; }
int adt_get_reg(const void *tree, int *path, const char *name, int index, u64 *address, u64 *size)
{ (void)tree; (void)path; (void)name; (void)index; (void)size; *address = BASE; return 0; }
int adt_getprop_copy(const void *tree, int node, const char *name, void *value, size_t size)
{ (void)tree; (void)node; (void)name; (void)value; (void)size; return -1; }
int pmgr_reset(int die, const char *name)
{ (void)die; reset_calls++; return reset_result[!strcmp(name, "ANS2")]; }
static u32 test_read32(u64 a)
{ assert(a >= BASE && a - BASE < sizeof(registers) && !(a & 3)); return registers[(a - BASE) / 4]; }
static void test_write32(u64 a, u32 value)
{
    assert(a >= BASE && a - BASE < sizeof(registers) && !(a & 3));
    registers[(a - BASE) / 4] = value;
    if (a == BASE + NVME_CC) {
        u32 *status = &registers[NVME_CSTS / 4];
        if ((value & NVME_CC_EN) && !fail_enable) *status |= NVME_CSTS_RDY;
        else if (!fail_disable) *status &= ~NVME_CSTS_RDY;
        if (FIELD_GET(NVME_CC_SHN, value) == NVME_CC_SHN_NORMAL && !fail_stop)
            *status = (*status & ~NVME_CSTS_SHST) | FIELD_PREP(NVME_CSTS_SHST, NVME_CSTS_SHST_DONE);
    }
    if (a == BASE + NVMMU_TCB_INVAL) {
        invalidations++; registers[NVMMU_TCB_STAT / 4] = bad_invalidation; return;
    }
    if (a != BASE + NVME_DB_LINEAR_ASQ && a != BASE + NVME_DB_LINEAR_IOSQ) return;
    struct nvme_queue *q = a == BASE + NVME_DB_LINEAR_ASQ ? &adminq : &ioq;
    assert(value == 0 && is_live(q->cmds) && is_live(q->cqes)); submissions++;
    bool drop = drop_completion || submissions == drop_submission;
    if (!q->adminq && q->cmds[0].opcode == NVME_CMD_READ) {
        last_dma = (void *)q->cmds[0].prp1;
        if (!drop) memset(last_dma, 0xa5, SZ_4K);
    }
    if (drop) return;
    q->cqes[q->cq_head] = (struct nvme_completion){.tag = bad_tag ? 255 : 0,
        .status = q->cq_phase | (completion_error ? 2 : 0)};
#ifndef BASELINE
    if (reenter_shutdown) {
        reenter_shutdown = false;
        unsigned before = live;
        assert(!nvme_shutdown() && live == before && nvme_command_active);
    }
#endif
}
static void test_write64(u64 address, u64 value)
{ address_writes++; test_write32(address, value); test_write32(address + 4, value >> 32); }
static int test_poll32(u64 address, u32 mask, u32 target, u32 timeout)
{ (void)timeout; return (test_read32(address) & mask) == target ? 0 : -1; }
int rtkit_recv(rtkit_dev_t *rtkit, struct rtkit_message *message)
{ assert(is_live(rtkit)); (void)message; return fail_receive ? -1 : 0; }
bool rtkit_send(rtkit_dev_t *rtkit, const struct rtkit_message *message)
{ assert(is_live(rtkit)); (void)message; return !fail_send; }

int main(int argc, char **argv)
{
    assert(argc == 2); const char *mode = argv[1];
#ifndef BASELINE
    assert(!strcmp(mode, "all"));
    unsigned scenarios = 34;
#ifdef SART_LIFECYCLE
    scenarios++;
#endif
    for (unsigned scenario = 0; scenario < scenarios; scenario++) {
        end_fake_epoch();
        nvme_initialized = nvme_owned = nvme_stopping = nvme_boot_attempted = false;
        nvme_controller_touched = nvme_controller_active = false;
        nvme_powered_down = nvme_reset_done = nvme_reset_failed = false;
        nvme_command_active = nvme_command_faulted = false;
        nvme_asc = NULL; nvme_rtkit = NULL; nvme_sart = NULL; nvme_read_buffer = NULL;
        memset(&adminq, 0, sizeof(adminq)); memset(&ioq, 0, sizeof(ioq));
        memset(registers, 0, sizeof(registers));
        registers[NVME_BOOT_STATUS / 4] = NVME_BOOT_STATUS_OK;
        submissions = invalidations = reset_calls = drop_submission = address_writes = 0;
        reset_result[0] = reset_result[1] = 0;
        fail_stop = fail_disable = fail_enable = drop_completion = bad_tag = bad_invalidation = completion_error = false;
        last_dma = NULL; reenter_shutdown = false;
        assert(nvme_shutdown());
        if (scenario < 10) {
            fail_allocation = scenario + 1;
            assert(!nvme_init() && !live && !nvme_owned);
            assert(!adminq.tcbs && !adminq.cmds && !adminq.cqes && !ioq.tcbs && !ioq.cmds && !ioq.cqes);
            fail_allocation = 0; assert(nvme_init()); assert(nvme_shutdown() && !live); checks++; continue;
        }
        if (scenario == 10) {
            fail_boot = fail_power = true;
            assert(!nvme_init() && live == 10 && nvme_rtkit && nvme_owned && !nvme_initialized);
            unsigned before = allocations_seen;
            assert(!nvme_init() && allocations_seen == before && !nvme_shutdown() && !frees);
            checks++; continue;
        }
        if (scenario >= 26 && scenario <= 31) {
            if (scenario == 26) registers[NVME_BOOT_STATUS / 4] = 0;
            if (scenario == 27) { registers[NVME_CSTS / 4] = NVME_CSTS_RDY; fail_disable = true; }
            fail_enable = scenario == 28;
            drop_submission = scenario == 29 ? 1 : scenario == 30 ? 2 : 0;
            fail_receive = fail_power = scenario == 31;
            assert(!nvme_init());
            if (scenario == 27 || scenario == 31) {
                assert(live == 10 && nvme_owned && !frees && !reset_calls);
                if (scenario == 27) assert(!address_writes && !power_calls);
                else assert(nvme_command_faulted && power_calls == 1);
                fail_disable = fail_receive = fail_power = false;
                assert(nvme_shutdown() && !live);
            } else {
                assert(!live && !nvme_owned && power_calls == 1 && reset_calls == 2);
                if (scenario == 26) assert(!address_writes);
            }
            checks++; continue;
        }
        assert(nvme_init() && live == 10);
        unsigned before = allocations_seen; assert(nvme_init() && allocations_seen == before);
        if (scenario == 32) {
            void *p = NULL; assert(!posix_memalign(&p, SZ_4K, SZ_4K)); memset(p, 0x55, SZ_4K);
            completion_error = true;
            assert(!nvme_read(1, 7, p) && !nvme_command_faulted);
            for (unsigned i = 0; i < SZ_4K; i++) assert(((u8 *)p)[i] == 0x55);
            completion_error = false; assert(nvme_read(1, 7, p)); free(p);
            assert(nvme_shutdown() && !live); checks++; continue;
        }
        if (scenario == 33) {
            for (unsigned i = 0; i < 200; i++) assert(nvme_flush(1));
            assert(ioq.cq_head == 200 % NVME_QUEUE_SIZE && ioq.cq_phase == 0);
            assert(nvme_shutdown() && !live); checks++; continue;
        }
#ifdef SART_LIFECYCLE
        if (scenario == 34) {
            fail_sart_release = true;
            assert(!nvme_shutdown() && nvme_stopping && live == 9 && frees == 1);
            assert(!nvme_rtkit && nvme_sart && nvme_asc && nvme_read_buffer && nvme_owned);
            unsigned powers = power_calls, resets = reset_calls;
            assert(!nvme_init() && !nvme_flush(1));
            fail_sart_release = false; assert(nvme_shutdown() && !live && !nvme_owned);
            assert(power_calls == powers && reset_calls == resets); checks++; continue;
        }
#endif
        if (scenario < 15) {
            fail_stop = scenario == 11; fail_disable = scenario == 12;
            fail_power = scenario == 13; fail_free = scenario == 14;
            assert(!nvme_shutdown() && live == 10 && !frees && nvme_stopping);
            assert(!nvme_init() && !nvme_flush(1));
            unsigned requests = submissions, powers = power_calls, resets = reset_calls;
            fail_stop = fail_disable = fail_power = fail_free = false;
            assert(nvme_shutdown() && !live && !nvme_owned && submissions == requests);
            if (scenario == 14) assert(power_calls == powers && reset_calls == resets);
        } else if (scenario < 20) {
            reset_result[0] = scenario == 15 || scenario == 17 ? PMGR_RESET_NOT_FOUND : scenario == 18 ? -1 : 0;
            reset_result[1] = scenario == 16 || scenario == 17 ? PMGR_RESET_NOT_FOUND : scenario == 19 ? -1 : 0;
            if (scenario < 17) assert(nvme_shutdown() && !live);
            else {
                assert(!nvme_shutdown() && live == 10 && nvme_reset_failed && !frees);
                unsigned calls = reset_calls; assert(!nvme_shutdown() && reset_calls == calls);
                if (scenario == 18) assert(calls == 1);
            }
        } else {
            void *p = NULL; assert(!posix_memalign(&p, SZ_4K, SZ_4K)); memset(p, 0x55, SZ_4K);
            drop_completion = scenario == 20; bad_tag = scenario == 21;
            bad_invalidation = scenario == 22; fail_receive = scenario == 23;
            reenter_shutdown = scenario == 24;
            bool ok = nvme_read(1, 7, p);
            if (scenario < 24) {
                assert(!ok && nvme_command_faulted && live == 10);
                for (unsigned i = 0; i < SZ_4K; i++) assert(((u8 *)p)[i] == 0x55);
                unsigned requests = submissions; assert(!nvme_flush(1) && submissions == requests);
                if (scenario == 21) assert(invalidations == 2);
                free(p);
                if (last_dma) { assert(is_live(last_dma)); memset(last_dma, 0xcd, SZ_4K); }
            } else {
                assert(ok && last_dma != p && is_live(last_dma));
                for (unsigned i = 0; i < SZ_4K; i++) assert(((u8 *)p)[i] == 0xa5);
                free(p);
            }
            fail_receive = false; drop_completion = bad_tag = bad_invalidation = false;
            assert(nvme_shutdown() && !live);
        }
        checks++;
    }
    end_fake_epoch();
    printf("NVMe lifecycle/owned read DMA: PASS (%u scenarios)\n", checks);
    return 0;
#else
    registers[NVME_BOOT_STATUS / 4] = NVME_BOOT_STATUS_OK;
    if (!strcmp(mode, "queue-oom")) {
        fail_allocation = 3; assert(!alloc_queue(&adminq));
        assert(!adminq.tcbs && !adminq.cmds && !adminq.cqes); return 0;
    }
    if (!strcmp(mode, "partial-boot")) {
        fail_boot = fail_power = true; assert(!nvme_init()); assert(live && nvme_rtkit && is_live(nvme_rtkit));
        assert(power_calls && !frees); return 0;
    }
    assert(nvme_init()); unsigned owned = live;
    if (!strcmp(mode, "invalid-tag")) {
        bad_tag = true; unsigned before = invalidations;
        assert(!nvme_flush(1)); assert(invalidations == before); return 0;
    }
    if (!strcmp(mode, "read-ownership")) {
        void *p = NULL; assert(!posix_memalign(&p, SZ_4K, SZ_4K));
        drop_completion = true; assert(!nvme_read(1, 0, p));
        free(p); assert(last_dma && is_live(last_dma));
        memset(last_dma, 0xcd, SZ_4K); return 0;
    }
    fail_power = !strcmp(mode, "power"); fail_free = !strcmp(mode, "buffer-free");
    fail_stop = !strcmp(mode, "controller-stop"); fail_disable = !strcmp(mode, "controller-disable");
    nvme_shutdown(); assert(live == owned && !frees && nvme_rtkit && is_live(nvme_rtkit));
    assert(!reset_calls || fail_free); return 0;
#endif
}
#endif

#ifdef TEST_SMC
static unsigned char shared[16];
static bool reply_ready;
static struct rtkit_message reply;
static unsigned notifications;
static bool missing_reply, wrong_id;
static bool smc_reentry __attribute__((unused));
static u32 test_read32(u64 address) { (void)address; abort(); }
static void test_write32(u64 address, u32 value) { (void)address; (void)value; abort(); }
static void test_write64(u64 address, u64 value) { (void)address; (void)value; abort(); }
static int test_poll32(u64 address, u32 mask, u32 target, u32 timeout)
{ (void)address; (void)mask; (void)target; (void)timeout; abort(); }
bool rtkit_send(rtkit_dev_t *rtkit, const struct rtkit_message *message)
{
    assert(is_live(rtkit)); if (fail_send) return false;
#ifndef BASELINE
    if (smc_reentry) {
        smc_reentry = false;
        assert(active_smc && active_smc->active_calls && !smc_shutdown(NULL) && live == 3);
    }
#endif
    reply = (struct rtkit_message){.ep = SMC_ENDPOINT};
    reply.msg = FIELD_GET(SMC_MSG_TYPE, message->msg) == SMC_INITIALIZE ?
        (u64)shared : message->msg & SMC_MSG_ID;
    if (wrong_id) reply.msg ^= BIT(12);
    reply_ready = !missing_reply; return true;
}
int rtkit_recv(rtkit_dev_t *rtkit, struct rtkit_message *message)
{
    assert(is_live(rtkit)); if (fail_receive) return -1;
    if (notifications) {
        notifications--; *message = (struct rtkit_message){.ep = SMC_ENDPOINT, .msg = SMC_NOTIFICATION};
        return 1;
    }
    if (!reply_ready) return 0;
    *message = reply; reply_ready = false; return 1;
}
int main(int argc, char **argv)
{
    assert(argc == 2); const char *mode = argv[1];
#ifndef BASELINE
    assert(!strcmp(mode, "all"));
    for (unsigned scenario = 0; scenario < 17; scenario++) {
        end_fake_epoch(); active_smc = NULL; reply_ready = missing_reply = wrong_id = false;
        notifications = 0; smc_reentry = false; memset(shared, 0, sizeof(shared));
        assert(smc_shutdown(NULL));
        if (scenario < 3) {
            fail_allocation = scenario + 1; assert(!smc_init() && !live && !active_smc);
            fail_allocation = 0;
            smc_dev_t *smc = smc_init(); assert(smc && smc_shutdown(smc) && !live); checks++; continue;
        }
        if (scenario == 3) {
            fail_boot = fail_power = true; assert(!smc_init() && active_smc && live == 3 && !frees);
            assert(!smc_init() && !smc_shutdown(NULL) && live == 3); checks++; continue;
        }
        if (scenario == 4) { fail_send = true; assert(!smc_init() && !active_smc && !live); checks++; continue; }
        if (scenario == 5) { missing_reply = true; assert(!smc_init() && active_smc && live == 3); checks++; continue; }
        if (scenario == 15) {
            smc_reentry = true; assert(!smc_init() && !active_smc && !live && power_calls == 1); checks++; continue;
        }
        smc_dev_t *smc = smc_init(); assert(smc && live == 3);
        unsigned before = allocations_seen; assert(!smc_init() && allocations_seen == before);
        if (scenario == 14) {
            assert(smc_write_u32(NULL, 1, 1) < 0 && smc_write_u32((void *)1, 1, 1) < 0);
            assert(!smc_shutdown((void *)1) && !frees && live == 3);
            assert(smc_shutdown(smc) && !live); checks++; continue;
        }
        if (scenario == 16) {
            smc_reentry = true; assert(!smc_write_u32(smc, 0x12345678, 42));
            assert(live == 3 && !frees && smc->stopping && !smc->active_calls);
            assert(smc_write_u32(smc, 0x12345678, 99) < 0);
            assert(smc_shutdown(smc) && !live); checks++; continue;
        }
        if (scenario == 6 || scenario == 7) {
            fail_power = scenario == 6; fail_free = scenario == 7;
            assert(!smc_shutdown(smc) && live == 3 && !frees && smc->stopping);
            assert(smc_write_u32(smc, 0x12345678, 42) < 0);
            unsigned powers = power_calls; fail_power = fail_free = false;
            assert(smc_shutdown(smc) && !live && !active_smc);
            if (scenario == 7) assert(power_calls == powers);
        } else if (scenario < 13) {
            fail_send = scenario == 8; fail_receive = scenario == 9;
            missing_reply = scenario == 10; wrong_id = scenario == 11;
            notifications = scenario == 12 ? 1000 : 0;
            assert(smc_write_u32(smc, 0x12345678, 42) < 0);
            if (scenario == 8) {
                fail_send = false;
                assert(!smc_write_u32(smc, 0x12345678, 43));
                assert(smc_shutdown(smc) && !live);
            } else {
                assert(smc->failed && live == 3 && !frees);
                assert(!smc_shutdown(smc) && !power_calls && !frees);
                assert(smc_write_u32(smc, 0x12345678, 99) < 0);
                u32 value; memcpy(&value, shared, 4); assert(value == 42);
            }
        } else {
            for (unsigned i = 0; i < 40; i++) {
                notifications = 2;
                assert(!smc_write_u32(smc, 0x12345678, i));
                u32 value; memcpy(&value, shared, 4); assert(value == i);
            }
            assert(smc_shutdown(smc) && !live);
        }
        checks++;
    }
    end_fake_epoch(); active_smc = NULL;
    printf("SMC lifecycle/requests: PASS (%u scenarios)\n", checks);
    return 0;
#else
    if (!strcmp(mode, "partial-boot")) {
        fail_boot = fail_power = true; assert(!smc_init()); assert(live && !frees); return 0;
    }
    if (!strcmp(mode, "initialize")) { fail_send = true; assert(!smc_init()); return 0; }
    smc_dev_t *smc = smc_init(); assert(smc); unsigned owned = live;
    if (!strcmp(mode, "send") || !strcmp(mode, "receive")) {
        fail_send = !strcmp(mode, "send"); fail_receive = !strcmp(mode, "receive");
        assert(smc_write_u32(smc, 0x12345678, 42) < 0); return 0;
    }
    fail_power = !strcmp(mode, "power"); fail_free = !strcmp(mode, "buffer-free");
    smc_shutdown(smc); assert(live == owned && !frees && is_live(smc)); return 0;
#endif
}
#endif
