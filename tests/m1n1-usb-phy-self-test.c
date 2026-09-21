/* SPDX-License-Identifier: MIT */
/* Compile the actual usb.c with ADT/power test doubles. MMIO operates only on
 * these process-owned arrays, using the real AArch64 write32/clear32 helpers.
 * This tests ordering and failure paths, not Apple PHY timing or hardware. */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "utils.h"

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled, inside the offline container"
#endif
#ifndef M1N1_USB_SOURCE
#error "Define M1N1_USB_SOURCE as the absolute path to the pinned usb.c"
#endif

static u32 atc_regs[32], drd_regs[32], pipe_regs[32];
static struct { char operation; u64 address; u32 value; } events[16];
static unsigned event_count, power_calls, path_calls, reg_calls, clear_calls;
static unsigned slot, fail_path, fail_reg, fail_power;
static bool inject_control_bits;

static void record(char operation, u64 address, u32 value)
{
    assert(power_calls == 3);
    bool atc = address == (u64)atc_regs || address == (u64)atc_regs + 4 ||
               address == (u64)atc_regs + 8 || address == (u64)atc_regs + 0x1c;
    bool pipe = address == (u64)pipe_regs + 0x0c || address == (u64)pipe_regs + 0x1c ||
                address == (u64)pipe_regs + 0x20;
    assert(atc || pipe);
    assert(event_count < ARRAY_SIZE(events));
    events[event_count].operation = operation;
    events[event_count].address = address;
    events[event_count++].value = value;
}

static void recorded_write32(u64 address, u32 value)
{
    record('w', address, value);
    write32(address, value);
}

static u32 recorded_clear32(u64 address, u32 bits)
{
    assert(address == (u64)atc_regs + 4);
    if (inject_control_bits && clear_calls == 0)
        atc_regs[1] |= 0x8004; /* Simulate unrelated bits changing after reset assertion. */
    clear_calls++;
    record('c', address, bits);
    return clear32(address, bits);
}

#define write32 recorded_write32
#define clear32 recorded_clear32
#include M1N1_USB_SOURCE
#undef write32
#undef clear32
#undef printf

static unsigned fake_adt;
void *adt = &fake_adt;

int debug_printf(const char *format, ...)
{
    (void)format;
    return 0;
}

int adt_path_offset_trace(const void *tree, const char *path, int *offsets)
{
    char expected[32];
    assert(tree == adt);
    path_calls++;
    assert(path_calls <= 2);
    snprintf(expected, sizeof(expected), path_calls == 1 ? FMT_DRD_PATH : FMT_ATC_PATH, slot);
    assert(strcmp(path, expected) == 0);
    offsets[0] = (int)path_calls;
    return path_calls == fail_path ? -1 : (int)path_calls;
}

int adt_get_reg(const void *tree, int *path, const char *prop, int index, u64 *address, u64 *size)
{
    assert(tree == adt && strcmp(prop, "reg") == 0 && size == NULL);
    reg_calls++;
    assert(reg_calls <= 3);
    assert(path[0] == (reg_calls == 1 ? 2 : 1));
    assert(index == (reg_calls == 3 ? 3 : 0));
    if (reg_calls == fail_reg)
        return -1;
    *address = reg_calls == 1 ? (u64)atc_regs : reg_calls == 2 ? (u64)drd_regs : (u64)pipe_regs;
    return 0;
}

int pmgr_adt_power_enable(const char *path)
{
    char expected[32];
    const char *formats[] = {FMT_ATC_PATH, FMT_DART_PATH, FMT_DRD_PATH};
    assert(power_calls < ARRAY_SIZE(formats));
    snprintf(expected, sizeof(expected), formats[power_calls++], slot);
    assert(strcmp(path, expected) == 0);
    assert(event_count == 0);
    return power_calls == fail_power ? -1 : 0;
}

static void reset_fixture(void)
{
    memset(atc_regs, 0xa5, sizeof(atc_regs));
    memset(drd_regs, 0xa5, sizeof(drd_regs));
    memset(pipe_regs, 0xa5, sizeof(pipe_regs));
    event_count = power_calls = path_calls = reg_calls = clear_calls = 0;
    fail_path = fail_reg = fail_power = 0;
    inject_control_bits = false;
}

static void expect_event(unsigned index, char operation, u64 address, u32 value)
{
    assert(events[index].operation == operation);
    assert(events[index].address == address);
    assert(events[index].value == value);
}

int main(void)
{
    unsigned cases = 0;
    for (slot = 0; slot < USB_IODEV_COUNT; slot++) {
        for (unsigned inject = 0; inject < 2; inject++) {
            reset_fixture();
            inject_control_bits = inject;
            assert(usb_phy_bringup(slot) == 0);
            assert(path_calls == 2 && reg_calls == 3 && power_calls == 3);
            assert(event_count == 9 && clear_calls == 2);
            expect_event(0, 'w', (u64)atc_regs + 8, 0x01c1000f);
            expect_event(1, 'w', (u64)atc_regs + 4, 3);
            expect_event(2, 'c', (u64)atc_regs + 4, 1);
            expect_event(3, 'c', (u64)atc_regs + 4, 2);
            expect_event(4, 'w', (u64)atc_regs + 0x1c, 0x008c0813);
            expect_event(5, 'w', (u64)atc_regs, 2);
            expect_event(6, 'w', (u64)pipe_regs + 0x0c, 0x22);
            expect_event(7, 'w', (u64)pipe_regs + 0x1c, 1);
            expect_event(8, 'w', (u64)pipe_regs + 0x20, 0x9332);
            assert(atc_regs[1] == (inject ? 0x8004U : 0U));
            assert(drd_regs[0] == 0xa5a5a5a5U);
            cases++;
        }
    }
    const u32 invalid[] = {USB_IODEV_COUNT, 0xffffffffU};
    for (unsigned i = 0; i < ARRAY_SIZE(invalid); i++) {
        reset_fixture();
        assert(usb_phy_bringup(invalid[i]) == -1);
        assert(path_calls == 0 && reg_calls == 0 && power_calls == 0 && event_count == 0);
        cases++;
    }
    slot = 0;
    for (unsigned i = 1; i <= 8; i++) {
        reset_fixture();
        if (i <= 2) fail_path = i;
        else if (i <= 5) fail_reg = i - 2;
        else fail_power = i - 5;
        assert(usb_phy_bringup(slot) == -1);
        assert(event_count == 0);
        assert(atc_regs[0] == 0xa5a5a5a5U && atc_regs[1] == 0xa5a5a5a5U);
        if (fail_path) {
            assert(path_calls == fail_path && reg_calls == 0 && power_calls == 0);
        } else if (fail_reg) {
            assert(path_calls == 2 && reg_calls == fail_reg && power_calls == 0);
        } else {
            assert(path_calls == 2 && reg_calls == 3 && power_calls == fail_power);
        }
        cases++;
    }
    printf("m1n1-usb-phy-cases=%u passed; hardware_acceptance=false\n", cases);
    return 0;
}
