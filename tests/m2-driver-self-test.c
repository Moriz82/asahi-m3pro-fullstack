/* SPDX-License-Identifier: GPL-2.0-only */
/* Compile verbatim, hash-pinned Linux function/definition excerpts. Only the
 * kernel services below are substitutes. Register reads are scripted or backed
 * by this process's arrays; no device, kernel module, or physical MMIO is used.
 * The real pinned polling macros run against a virtual clock/delay counter. */
#include <errno.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdarg.h>
#include <stdlib.h>
#include <string.h>

typedef unsigned char u8;
typedef unsigned int u32;
typedef unsigned long long u64;
typedef long long s64;
typedef u64 dma_addr_t;
typedef s64 ktime_t;
typedef int spinlock_t;
typedef int irqreturn_t;
enum { IRQ_NONE, IRQ_HANDLED, GENPD_STATE_OFF, GENPD_STATE_ON };
struct device { int unused; };
struct generic_pm_domain { const char *name; int status; spinlock_t slock; };
struct reset_controller_dev { int unused; };
struct iommu_device { int unused; };
enum io_pgtable_fmt { APPLE_DART, APPLE_DART2 };

#define CHECK(condition) do { if (!(condition)) { \
    fprintf(stderr, "check failed: %s at %s:%d\n", #condition, __FILE__, __LINE__); \
    exit(1); \
} } while (0)
#define BIT(n) (1UL << (n))
#define GENMASK(h, l) ((~0UL << (l)) & (~0UL >> (63 - (h))))
#define FIELD_PREP(mask, value) (((unsigned long)(value) << __builtin_ctzl(mask)) & (mask))
#define FIELD_GET(mask, value) (((unsigned long)(value) & (mask)) >> __builtin_ctzl(mask))
#define container_of(pointer, type, field) ((type *)((char *)(pointer) - offsetof(type, field)))
#define ARRAY_SIZE(array) (sizeof(array) / sizeof((array)[0]))
#define BITS_TO_U32(bits) (((bits) + 31) / 32)
#define DECLARE_BITMAP(name, bits) unsigned long name[((bits) + 63) / 64]
#define for_each_set_bit(index, map, size) \
    for ((index) = 0; (index) < (int)(size); (index)++) \
        if (((map)[(index) / 64] >> ((index) % 64)) & 1UL)
#define __iomem
#define U32_MAX UINT32_MAX
#define NSEC_PER_USEC 1000
#define barrier() __asm__ __volatile__("" : : : "memory")
#define cpu_relax() ((void)0)

static unsigned locks, unlocks, sleeps, errors, cases;
static s64 virtual_us;
static char error_log[8192];
static void lock(spinlock_t *value) { CHECK(!*value); *value = 1; locks++; }
static void unlock(spinlock_t *value) { CHECK(*value == 1); *value = 0; unlocks++; }
#define spin_lock_irqsave(value, flags) do { (flags) = 0xa55a; lock(value); } while (0)
#define spin_unlock_irqrestore(value, flags) do { CHECK((flags) == 0xa55a); unlock(value); } while (0)
static ktime_t ktime_get(void) { return virtual_us++; }
static ktime_t ktime_add_us(ktime_t now, u64 delay) { return now + delay; }
static int ktime_compare(ktime_t left, ktime_t right) { return (left > right) - (left < right); }
static void udelay(unsigned long delay) { CHECK(delay <= 100); virtual_us += delay; }
static void usleep_range(unsigned long lower, unsigned long upper)
{
    CHECK(lower == 1 && upper == 2 && locks == unlocks);
    sleeps++;
}
static void log_error(struct device *dev, const char *format, ...)
{
    (void)dev;
    va_list args;
    size_t used = strlen(error_log);
    va_start(args, format);
    int written = vsnprintf(error_log + used, sizeof(error_log) - used, format, args);
    va_end(args);
    CHECK(written >= 0 && (size_t)written < sizeof(error_log) - used);
    errors++;
}
#define dev_err log_error
#define dev_err_ratelimited log_error
#define dev_dbg(...) ((void)0)

#include "poll-snippet.h"

static void reset_common(void)
{
    locks = unlocks = sleeps = errors = 0;
    virtual_us = 0;
    memset(error_log, 0, sizeof(error_log));
}

#ifdef TEST_PMGR

struct regmap { int unused; };
static int regmap_read(struct regmap *, unsigned, u32 *);
static int regmap_write(struct regmap *, unsigned, u32);
static int regmap_update_bits(struct regmap *, unsigned, u32, u32);
#include "pmgr-snippet.h"

struct sample { u32 value; int error; };
static struct sample samples[4][3];
static unsigned reads[4], write_count, update_count;
static u32 writes[4], masks[4], updates[4];
static struct regmap map;
static struct apple_pmgr_ps fixture;

/* Reads do not infer success from preceding writes. Each test independently
 * supplies the observed register values/errors for each write phase. */
static int regmap_read(struct regmap *regmap, unsigned offset, u32 *value)
{
    CHECK(regmap == &map && offset == fixture.offset && write_count < 4);
    unsigned index = reads[write_count]++;
    struct sample result = samples[write_count][index < 2 ? index : 2];
    if (!result.error)
        *value = result.value;
    return result.error;
}
static int regmap_write(struct regmap *regmap, unsigned offset, u32 value)
{
    CHECK(regmap == &map && offset == fixture.offset && write_count < 4);
    writes[write_count++] = value;
    return 0;
}
static int regmap_update_bits(struct regmap *regmap, unsigned offset, u32 mask, u32 value)
{
    CHECK(regmap == &map && offset == fixture.offset && update_count < 4);
    CHECK(fixture.genpd.slock == 1);
    masks[update_count] = mask;
    updates[update_count++] = value;
    return 0;
}
static void supply(unsigned phase, u32 value, int error)
{
    for (unsigned i = 0; i < 3; i++)
        samples[phase][i] = (struct sample){value, error};
}
static void reset_pmgr(u32 initial)
{
    reset_common();
    memset(&fixture, 0, sizeof(fixture));
    memset(samples, 0, sizeof(samples));
    memset(reads, 0, sizeof(reads));
    memset(writes, 0, sizeof(writes));
    memset(masks, 0, sizeof(masks));
    memset(updates, 0, sizeof(updates));
    write_count = update_count = 0;
    fixture.regmap = &map;
    fixture.offset = 0x10;
    fixture.genpd.name = "fixture-domain";
    fixture.genpd.status = GENPD_STATE_ON;
    supply(0, initial, 0);
}
static void check_power_transitions(void)
{
    const u32 states[] = {APPLE_PMGR_PS_ACTIVE, APPLE_PMGR_PS_CLKGATE, APPLE_PMGR_PS_PWRGATE};
    const u32 retained = BIT(22) | FIELD_PREP(APPLE_PMGR_PS_MIN, 3) | FIELD_PREP(APPLE_PMGR_PS_ACTUAL, 15);
    const u32 initial = retained | APPLE_PMGR_FLAGS | APPLE_PMGR_AUTO_ENABLE |
                        APPLE_PMGR_DEV_DISABLE | APPLE_PMGR_PS_RESET | 15;
    for (unsigned s = 0; s < ARRAY_SIZE(states); s++)
        for (unsigned flags = 0; flags < 4; flags++)
            for (unsigned automatic = 0; automatic < 2; automatic++)
                for (unsigned external = 0; external < 2; external++) {
                    u32 target = states[s];
                    bool prep = target != APPLE_PMGR_PS_ACTIVE && flags;
                    reset_pmgr(initial);
                    fixture.force_disable = flags & 1;
                    fixture.force_reset = flags & 2;
                    fixture.externally_clocked = external;
                    if (prep)
                        supply(1, APPLE_PMGR_DEV_DISABLE | APPLE_PMGR_PS_RESET, 0);
                    u32 observed = external && target == APPLE_PMGR_PS_ACTIVE ? APPLE_PMGR_PS_CLKGATE : target;
                    supply(1 + prep, FIELD_PREP(APPLE_PMGR_PS_ACTUAL, observed), 0);
                    CHECK(apple_pmgr_ps_set(&fixture.genpd, target, automatic) == 0);
                    CHECK(write_count == 1 + prep + automatic && errors == 0);
                    if (prep)
                        CHECK(writes[0] == (initial & ~(APPLE_PMGR_AUTO_ENABLE | APPLE_PMGR_FLAGS)));
                    CHECK(writes[prep] == (retained | target));
                    if (automatic)
                        CHECK(writes[1 + prep] == (retained | target | APPLE_PMGR_AUTO_ENABLE));
                    CHECK(locks == 0 && unlocks == 0);
                    cases++;
                }
    /* The force flags must add bits, not merely preserve already-set bits. */
    for (unsigned flags = 1; flags < 4; flags++) {
        reset_pmgr(APPLE_PMGR_PS_ACTIVE);
        fixture.force_disable = flags & 1;
        fixture.force_reset = flags & 2;
        u32 required = (flags & 1 ? APPLE_PMGR_DEV_DISABLE : 0) | (flags & 2 ? APPLE_PMGR_PS_RESET : 0);
        supply(1, required, 0);
        supply(2, 0, 0);
        CHECK(apple_pmgr_ps_power_off(&fixture.genpd) == 0);
        CHECK(write_count == 2 && writes[0] == (15 | required) && writes[1] == 0);
        cases++;
    }
}
static void check_power_failures(void)
{
    reset_pmgr(0);
    supply(0, 0, -EIO);
    CHECK(apple_pmgr_ps_power_on(&fixture.genpd) == -EIO && write_count == 0);
    cases++;
    for (unsigned external = 0; external < 2; external++)
        for (unsigned failure = 0; failure < 2; failure++) {
            reset_pmgr(0);
            fixture.externally_clocked = external;
            supply(1, 0, failure ? -EIO : 0);
            CHECK(apple_pmgr_ps_power_on(&fixture.genpd) == (failure ? -EIO : -ETIMEDOUT));
            CHECK(errors == 1 && strstr(error_log, "Failed to reach power state"));
            CHECK(write_count == 2 && writes[1] == (15 | APPLE_PMGR_AUTO_ENABLE));
            if (failure) CHECK(reads[1] == 1);
            if (!failure) CHECK(reads[1] > 2 && reads[1] < 200);
            cases++;
        }
    reset_pmgr(APPLE_PMGR_RESET | 15);
    supply(1, 0, 0);
    CHECK(apple_pmgr_ps_power_off(&fixture.genpd) == 0);
    CHECK(errors == 1 && strstr(error_log, "powering off with RESET active"));
    cases++;
    /* Real polling macros must accept delayed success and the external-clock
     * threshold, not require the fully active state on those domains. */
    reset_pmgr(0);
    supply(1, FIELD_PREP(APPLE_PMGR_PS_ACTUAL, 15), 0);
    samples[1][0].value = 0;
    CHECK(apple_pmgr_ps_power_on(&fixture.genpd) == 0 && reads[1] == 2 && errors == 0);
    cases++;
    reset_pmgr(APPLE_PMGR_RESET);
    supply(1, FIELD_PREP(APPLE_PMGR_PS_ACTUAL, 15), 0);
    CHECK(apple_pmgr_ps_power_on(&fixture.genpd) == 0 && errors == 0);
    cases++;
}
static void check_preliminary_failures(void)
{
    /* genpd retains logical ON on a negative power_off result and may then
     * skip power_on during resume. After a successful final PWRGATE poll, an
     * earlier diagnostic must not replace success with an error. Nor may we
     * stop after partially changing disable/reset/auto-PM without rollback.
     * The real genpd callers are reviewed separately; not executed here. */
    for (unsigned flags = 1; flags < 4; flags++)
        for (unsigned initial_error = 0; initial_error < 2; initial_error++)
            for (unsigned final_error = 0; final_error < 3; final_error++) {
                reset_pmgr(15 | APPLE_PMGR_AUTO_ENABLE);
                fixture.force_disable = flags & 1;
                fixture.force_reset = flags & 2;
                u32 required = (flags & 1 ? APPLE_PMGR_DEV_DISABLE : 0) |
                               (flags & 2 ? APPLE_PMGR_PS_RESET : 0);
                supply(1, 0, initial_error ? -EIO : 0);
                supply(2, final_error == 1 ? FIELD_PREP(APPLE_PMGR_PS_ACTUAL, 15) : 0,
                       final_error == 2 ? -EIO : 0);
                int expected_ret = final_error == 1 ? -ETIMEDOUT : final_error == 2 ? -EIO : 0;
                int ret = apple_pmgr_ps_power_off(&fixture.genpd);
                CHECK(ret == expected_ret);
                CHECK(write_count == 2 && writes[0] == (15 | required) && writes[1] == 0);
                CHECK(errors == 1 + (final_error != 0) && strstr(error_log, "Failed to set reset/disable bits"));
                CHECK(!!strstr(error_log, "Failed to reach power state") == (final_error != 0));
                if (initial_error) CHECK(reads[1] == 1);
                else CHECK(reads[1] > 2 && reads[1] < 200);
                CHECK(locks == 0 && unlocks == 0);
                cases++;
            }
}
static void check_status_and_reset(void)
{
    const u32 values[] = {0, FIELD_PREP(APPLE_PMGR_PS_ACTUAL, 15), 15 | APPLE_PMGR_AUTO_ENABLE,
                          15, APPLE_PMGR_AUTO_ENABLE, APPLE_PMGR_RESET};
    for (unsigned i = 0; i < ARRAY_SIZE(values); i++) {
        reset_pmgr(values[i]);
        CHECK(apple_pmgr_ps_is_active(&fixture) == (i == 1 || i == 2));
        CHECK(apple_pmgr_reset_status(&fixture.rcdev, 0) == (i == 5));
        CHECK(write_count == 0 && update_count == 0);
        cases++;
    }
    for (unsigned off = 0; off < 2; off++) {
        reset_pmgr(0);
        fixture.genpd.status = off ? GENPD_STATE_OFF : GENPD_STATE_ON;
        CHECK(apple_pmgr_reset_reset(&fixture.rcdev, 0) == 0);
        CHECK(locks == 2 && unlocks == 2 && !fixture.genpd.slock && sleeps == 1 && update_count == 4);
        CHECK(masks[0] == (APPLE_PMGR_FLAGS | APPLE_PMGR_DEV_DISABLE) && updates[0] == APPLE_PMGR_DEV_DISABLE);
        CHECK(masks[1] == (APPLE_PMGR_FLAGS | APPLE_PMGR_RESET) && updates[1] == APPLE_PMGR_RESET);
        CHECK(masks[2] == masks[1] && updates[2] == 0);
        CHECK(masks[3] == masks[0] && updates[3] == 0);
        CHECK(errors == 2 * off);
        cases++;
    }
}
int main(int argc, char **argv)
{
    _Static_assert(sizeof(unsigned long) == 8 && sizeof(u32) == 4, "64-bit kernel primitive model required");
    CHECK(argc == 1);
    check_power_transitions();
    check_power_failures();
    check_status_and_reset();
    check_preliminary_failures();
    printf("preliminary_fault_policy=logs_error_then_returns_final_transition_status\n");
    printf("pmgr_behavior_cases=%u passed; hardware_acceptance=false\n", cases);
    return 0;
}

#else

static u32 readl(const void *);
static void writel(u32, void *);
#include "dart-snippet.h"

static u32 registers[0x2000 / 4];
static struct { unsigned offset; u32 value; } events[512];
static unsigned event_count, command_count, poll_reads, settle_after, timeout_command;
static bool t8110, command_mode;
static struct apple_dart fixture;
static struct apple_dart_stream_map streams;

static unsigned register_offset(const void *address)
{
    uintptr_t offset = (uintptr_t)address - (uintptr_t)registers;
    CHECK(offset < sizeof(registers) && !(offset & 3));
    return (unsigned)offset;
}
static u32 readl(const void *address)
{
    unsigned offset = register_offset(address);
    u32 value = registers[offset / 4];
    if (command_mode) {
        CHECK(fixture.lock == 1);
        CHECK(offset == (t8110 ? DART_T8110_TLB_CMD : DART_T8020_STREAM_COMMAND));
        u32 busy = t8110 ? DART_T8110_TLB_CMD_BUSY : DART_T8020_STREAM_COMMAND_BUSY;
        if (++poll_reads <= settle_after || command_count == timeout_command)
            value |= busy;
        else
            value &= ~busy;
    }
    return value;
}
static void writel(u32 value, void *address)
{
    unsigned offset = register_offset(address);
    CHECK(event_count < ARRAY_SIZE(events));
    events[event_count].offset = offset;
    events[event_count++].value = value;
    registers[offset / 4] = value;
    if (command_mode) {
        CHECK(fixture.lock == 1);
        if (offset == (t8110 ? DART_T8110_TLB_CMD : DART_T8020_STREAM_COMMAND)) {
            command_count++;
            poll_reads = 0;
        }
    }
}
static void reset_dart(unsigned count, bool modern, bool command)
{
    reset_common();
    memset(&fixture, 0, sizeof(fixture));
    memset(&streams, 0, sizeof(streams));
    memset(registers, 0, sizeof(registers));
    memset(events, 0, sizeof(events));
    event_count = command_count = poll_reads = settle_after = timeout_command = 0;
    t8110 = modern;
    command_mode = command;
    fixture.regs = registers;
    fixture.num_streams = count;
    streams.dart = &fixture;
}
static void check_commands(void)
{
    const unsigned sizes[] = {1, 16, 32, 33, 64, 65, 128, 256};
    for (unsigned size = 0; size < ARRAY_SIZE(sizes); size++)
        for (unsigned empty = 0; empty < 2; empty++)
            for (unsigned delayed = 0; delayed < 2; delayed++) {
                reset_dart(sizes[size], true, true);
                settle_after = delayed ? 2 : 0;
                for (unsigned sid = 0; !empty && sid < sizes[size]; sid++)
                    streams.sidmap[sid / 64] |= BIT(sid % 64);
                CHECK(apple_dart_t8110_hw_tlb_command(&streams, DART_T8110_TLB_CMD_OP_FLUSH_SID) == 0);
                CHECK(event_count == (empty ? 0 : sizes[size]) && errors == 0);
                for (unsigned sid = 0; sid < event_count; sid++) {
                    CHECK(events[sid].offset == DART_T8110_TLB_CMD);
                    CHECK(events[sid].value == (0x100 | sid));
                }
                CHECK(locks == 1 && unlocks == 1 && !fixture.lock);
                cases++;
            }
    for (unsigned fail = 1; fail <= 3; fail++) {
        reset_dart(256, true, true);
        streams.sidmap[0] = BIT(0);
        streams.sidmap[1] = BIT(0);
        streams.sidmap[3] = BIT(63);
        timeout_command = fail;
        CHECK(apple_dart_t8110_hw_tlb_command(&streams, DART_T8110_TLB_CMD_OP_FLUSH_SID) == -ETIMEDOUT);
        CHECK(event_count == fail && errors == 1 && strstr(error_log, "busy bit did not clear"));
        CHECK(poll_reads > 2 && poll_reads < 200 && locks == 1 && unlocks == 1 && !fixture.lock);
        const unsigned selected[] = {0, 64, 255};
        for (unsigned i = 0; i < fail; i++) CHECK(events[i].value == (0x100 | selected[i]));
        cases++;
    }
    /* T8020 is a shared-driver regression control, not the T6030 backend. Its
     * real descriptor supports 16 streams; do not invent larger hardware. */
    for (unsigned fail = 0; fail < 2; fail++) {
        reset_dart(16, false, true);
        streams.sidmap[0] = 0x8005;
        timeout_command = fail;
        CHECK(apple_dart_t8020_hw_stream_command(&streams, DART_T8020_STREAM_COMMAND_INVALIDATE) == (fail ? -ETIMEDOUT : 0));
        CHECK(event_count == 2 && events[0].offset == 0x34 && events[0].value == 0x8005);
        CHECK(events[1].offset == 0x20 && events[1].value == BIT(20));
        CHECK(errors == fail && locks == 1 && unlocks == 1 && !fixture.lock);
        cases++;
    }
}
static void check_faults(void)
{
    const unsigned sizes[] = {1, 31, 32, 33, 64, 65, 128, 256};
    const char *names[] = {"NO TTBR FOR IOVA", "NO PGD FOR IOVA", "NO PMD FOR IOVA",
                           "NO PTE FOR IOVA", "WRITE FAULT", "READ FAULT"};
    for (unsigned size = 0; size < ARRAY_SIZE(sizes); size++)
        for (unsigned code = 0; code < 9; code++)
            for (unsigned present = 0; present < 2; present++) {
                unsigned stream = sizes[size] - 1;
                u32 error_code = code < 6 ? BIT(code) : code == 6 ? 0 : code == 7 ? 3 : 0x7fff;
                u32 error = FIELD_PREP(DART_T8110_ERROR_STREAM, stream) | error_code |
                            (present ? DART_T8110_ERROR_FLAG : 0);
                reset_dart(sizes[size], true, false);
                registers[DART_T8110_ERROR / 4] = error;
                registers[DART_T8110_ERROR_ADDR_LO / 4] = 0xdeadbeef;
                registers[DART_T8110_ERROR_ADDR_HI / 4] = 0xfedcba98;
                CHECK(apple_dart_t8110_irq(0, &fixture) == (present ? IRQ_HANDLED : IRQ_NONE));
                CHECK(errors == present && locks == 0 && unlocks == 0);
                if (!present) CHECK(event_count == 0);
                else {
                    CHECK(event_count == 1 + BITS_TO_U32(sizes[size]));
                    CHECK(events[0].offset == DART_T8110_ERROR && events[0].value == error);
                    for (unsigned bank = 0; bank < BITS_TO_U32(sizes[size]); bank++) {
                        CHECK(events[bank + 1].offset == DART_T8110_ERROR_STREAMS + bank * 4);
                        CHECK(events[bank + 1].value == UINT32_MAX);
                    }
                    CHECK(strstr(error_log, code < 6 ? names[code] : "unknown"));
                    CHECK(strstr(error_log, "at 0xfedcba98deadbeef"));
                    char expected[48];
                    snprintf(expected, sizeof(expected), "stream:%u code:0x%x", stream, error_code);
                    CHECK(strstr(error_log, expected));
                }
                cases++;
            }
    const char *legacy_names[] = {"NO TTBR FOR IOVA", "NO PMD FOR IOVA", "NO PTE FOR IOVA", "WRITE FAULT", "READ FAULT"};
    for (unsigned code = 0; code < 7; code++)
        for (unsigned present = 0; present < 2; present++) {
            reset_dart(16, false, false);
            u32 error = (present ? DART_T8020_ERROR_FLAG : 0) | FIELD_PREP(DART_T8020_ERROR_STREAM, 15) |
                        (code < 5 ? BIT(code) : code == 5 ? 0 : 3);
            registers[DART_T8020_ERROR / 4] = error;
            registers[DART_T8020_ERROR_ADDR_LO / 4] = 0x12345678;
            registers[DART_T8020_ERROR_ADDR_HI / 4] = 0xabcdef;
            CHECK(apple_dart_t8020_irq(0, &fixture) == (present ? IRQ_HANDLED : IRQ_NONE));
            CHECK(event_count == present && errors == present);
            if (present) {
                CHECK(events[0].offset == DART_T8020_ERROR && events[0].value == error);
                CHECK(strstr(error_log, code < 5 ? legacy_names[code] : "unknown"));
                CHECK(strstr(error_log, "at 0xabcdef12345678"));
            }
            cases++;
        }
}
int main(void)
{
    _Static_assert(sizeof(unsigned long) == 8 && sizeof(u32) == 4, "64-bit kernel primitive model required");
    check_commands();
    check_faults();
    printf("dart_behavior_cases=%u passed; hardware_acceptance=false\n", cases);
    return 0;
}
#endif
