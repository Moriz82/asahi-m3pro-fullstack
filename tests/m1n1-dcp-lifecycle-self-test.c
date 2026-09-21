/* SPDX-License-Identifier: MIT */
/* Actual production lifecycle functions; fake hardware and tracked owners. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <setjmp.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int dart_dev_t;
typedef int iova_domain_t;
typedef int asc_dev_t;
typedef int afk_epic_t;
typedef int dcp_system_if_t;
typedef int dcp_dpav_if_t;
typedef int dcp_dptx_if_t;
typedef int dptx_phy_t;
struct rtkit_dev;
typedef struct rtkit_dev rtkit_dev_t;
typedef struct dcp_iboot_if { int value; } dcp_iboot_if_t;
#include "types.inc"
static unsigned cases;
static int diagnostic(const char *format, ...) { (void)format; return 0; }

#ifdef TEST_OWNERS
static int token[10];
static void *adt;
enum { V13_5 = 135, DART_ERR_UNSUPPORTED_PT_REGION = -2 };
static struct { int version; } os_firmware = {V13_5};
static unsigned failure, init_failure, released, power_calls, resets, client_calls, afk_calls;
static dcp_dev_t *allocated;
static unsigned stage;
#ifdef STORAGE_LIFECYCLE
static bool smc_failure;
static bool smc_shutdown(void *smc) { assert(!smc); return !smc_failure; }
#endif
static void *allocate(size_t count, size_t size)
{ assert(!allocated && count == 1 && size == sizeof(dcp_dev_t)); return allocated = calloc(count, size); }
static void release(void *pointer)
{
    if (!pointer) return;
    assert(pointer == allocated && stage == 4);
    free(pointer); allocated = NULL; released++;
}
static int adt_path_offset(void *tree, const char *path)
{ assert(tree == adt && path[0] == '/'); return 1; }
static int adt_first_child_offset(void *tree, int node)
{ assert(tree == adt && node == 1); return 2; }
static int get_sid(void *tree, int node, const char *name, u32 *sid)
{ assert(tree == adt && node == 2 && !strcmp(name, "reg")); *sid = 5; return 0; }
#define ADT_GETPROP get_sid
static int pmgr_adt_power_enable(const char *path) { (void)path; return 0; }
static void mdelay(unsigned delay) { assert(delay == 25); }
static dart_dev_t *dart_init_adt(const char *path, int instance, int sid, bool keep)
{ (void)path; assert(!instance && keep); return init_failure == 1 ? NULL : &token[sid ? 0 : 1]; }
static u64 dart_vm_base(dart_dev_t *dart) { assert(dart == &token[0]); return 1ULL << 40; }
static int dart_setup_pt_region(dart_dev_t *dart, const char *path, int sid, u64 base)
{ (void)dart; (void)path; (void)sid; assert(base == 1ULL << 40); return 0; }
static iova_domain_t *iovad_init(u64 start, u64 end)
{ assert(end - start == 0x10000000); return init_failure == 2 ? NULL : &token[2]; }
static int dcp_create_firmware_mappings(const display_config_t *cfg, dcp_dev_t *dev)
{ assert(cfg && dev); return 0; }
static int pmgr_reset(int die, const char *name)
{ assert(die == 0 && !strcmp(name, "DISP_CPU")); resets++; return failure == 7 ? -1 : 0; }
static asc_dev_t *asc_init(const char *path)
{ assert(!strcmp(path, "/arm-io/dcp")); return init_failure == 3 ? NULL : &token[3]; }
static rtkit_dev_t *rtkit_init(const char *name, asc_dev_t *asc, dart_dev_t *dart,
                             iova_domain_t *domain, void *opaque, bool flag)
{ assert(!strcmp(name, "dcp") && asc && dart && domain && !opaque && !flag);
  return init_failure == 4 ? NULL : (void *)&token[4]; }
static bool rtkit_boot(rtkit_dev_t *rtk) { assert(rtk); return init_failure != 5; }
static afk_epic_t *afk_epic_init(rtkit_dev_t *rtk)
{ assert(rtk); return init_failure == 6 ? NULL : &token[5]; }
static int dcp_hdmi_dptx_init(dcp_dev_t *dev, const display_config_t *cfg)
{ assert(dev && cfg); return 0; }
static int child(unsigned which, void *pointer)
{
    client_calls++; assert(stage == 0);
    if (failure == which) return -1;
    if (pointer) {
#ifndef BASELINE
        if (which == 1) allocated->iboot_ep = NULL;
#endif

        if (which == 2) allocated->system_ep = NULL;
        if (which == 3) allocated->dptx_ep = NULL;
        if (which == 4) allocated->dpav_ep = NULL;
    }
    return 0;
}
#ifndef BASELINE
static int dcp_ib_shutdown(dcp_iboot_if_t *p) { return child(1, p); }
#endif
static int dcp_system_shutdown(dcp_system_if_t *p) { return child(2, p); }
static int dcp_dptx_shutdown(dcp_dptx_if_t *p) { return child(3, p); }
static int dcp_dpav_shutdown(dcp_dpav_if_t *p) { return child(4, p); }
static int afk_epic_shutdown(afk_epic_t *afk)
{
    afk_calls++; assert(stage == 0); if (failure == 5 && afk) return -1; stage = 1;
#ifndef BASELINE
    if (allocated->quiesced) stage = 2;
#endif
    return 0;
}
static bool power(rtkit_dev_t *rtk)
{ assert(rtk && stage == 1); power_calls++; if (failure == 6) return false; stage = 2; return true; }
static bool rtkit_quiesce(rtkit_dev_t *rtk) { return power(rtk); }
static bool rtkit_sleep(rtkit_dev_t *rtk) { return power(rtk); }
static bool rtkit_free(rtkit_dev_t *rtk)
{ if (!rtk) { stage = 4; return true; } assert(stage == 2); if (failure == 8) return false; stage = 3; return true; }
#ifdef DART_LIFECYCLE
static unsigned cleanup_failure;
static bool dart_is_faulted(dart_dev_t *dart) { return !dart; }
static bool dart_shutdown(dart_dev_t *dart)
{ if (!dart) return true; assert(stage >= 3);
  if (cleanup_failure == (dart == &token[1] ? 1U : 3U)) return false;
  stage = 4; released++; return true; }
static bool iovad_shutdown(iova_domain_t *domain, dart_dev_t *dart)
{ if (!domain) return true; assert(dart && stage == 4);
  if (cleanup_failure == 2) return false;
  released++; return true; }
#else
static void dart_shutdown(dart_dev_t *dart) { assert(dart && stage >= 3); stage = 4; released++; }
static void iovad_shutdown(iova_domain_t *domain, dart_dev_t *dart)
{ assert(domain && dart && stage == 4); released++; }
#endif
#ifndef BASELINE
static void asc_free(asc_dev_t *asc) { assert(asc && stage == 4); released++; }
#endif
int dcp_shutdown(dcp_dev_t *dcp, bool sleep);
#define calloc allocate
#define free release
#define printf diagnostic
#include "lifecycle.inc"
#undef calloc
#undef free
#undef printf
static const display_config_t cfg = {.dcp = "/arm-io/dcp", .dcp_dart = "/arm-io/dart-dcp",
    .disp_dart = "/arm-io/dart-disp0", .pmgr_dev = "DISP_CPU"};
static void reset(void)
{ assert(!allocated); failure = init_failure = released = power_calls = resets = client_calls = afk_calls = stage = 0; }
static dcp_dev_t *start(void)
{
    reset(); dcp_dev_t *dev = dcp_init(&cfg); assert(dev && dev == allocated);
#ifndef BASELINE
    dev->iboot_ep = (void *)&token[6];
#endif
    dev->system_ep = &token[7]; dev->dptx_ep = &token[8]; dev->dpav_ep = &token[9];
    return dev;
}
static void failed(unsigned which)
{
    dcp_dev_t *dev = start(); failure = which;
    assert(dcp_shutdown(dev, true) < 0 && allocated == dev && !released);
#ifndef BASELINE
    assert(active_dcp == dev && dev->stopping);
    assert(!dcp_init(&cfg));
    if (which == 7) {
        assert(dev->reset_failed && dcp_shutdown(NULL, false) < 0);
        /* End the fake hardware epoch only; not a production reset operation. */
        free(allocated); allocated = active_dcp = NULL;
    } else {
        bool already_quiesced = dev->quiesced;
        unsigned previous_power = power_calls;
        failure = 0; stage = 0;
        /* The fake power/free dependencies enforce the retained quiesced phase. */
        if (already_quiesced) stage = 0;
        assert(!dcp_shutdown(NULL, true) && !allocated && !active_dcp);
        assert(power_calls == previous_power + !already_quiesced);
    }
#endif
    cases++;
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "child")) failed(2);
    else if (!strcmp(argv[1], "afk")) failed(5);
    else if (!strcmp(argv[1], "power")) failed(6);
    else if (!strcmp(argv[1], "free")) failed(8);
    else {
        assert(!strcmp(argv[1], "all"));
#ifndef BASELINE
        for (unsigned which = 1; which <= 8; which++) failed(which);
        for (unsigned sleep = 0; sleep < 2; sleep++) {
            dcp_dev_t *dev = start(); assert(!dcp_init(&cfg));
            assert(!dcp_shutdown(dev, sleep) && !allocated && !active_dcp);
            assert(power_calls == 1 && resets == sleep && released == 5);
            assert(!dcp_shutdown(NULL, sleep)); cases++;
        }
        for (unsigned which = 1; which <= 6; which++) {
            reset(); init_failure = which;
            assert(!dcp_init(&cfg));
            if (which >= 2 && which <= 4) {
                assert(allocated && active_dcp == allocated && !released);
                stage = 0;
                assert(dcp_shutdown(NULL, false) < 0 && !dcp_init(&cfg));
                free(allocated); allocated = active_dcp = NULL;
            } else assert(!allocated && !active_dcp);
            cases++;
        }
        reset(); init_failure = 5; failure = 6;
        assert(!dcp_init(&cfg) && allocated && !released);
        failure = 0; stage = 0; assert(!dcp_shutdown(NULL, false) && !allocated); cases++;
#ifdef STORAGE_LIFECYCLE
        smc_failure = true; assert(dcp_shutdown(NULL, false) < 0 && !allocated); cases++;
        smc_failure = false; dcp_dev_t *dev = start(); smc_failure = true;
        assert(dcp_shutdown(dev, false) < 0 && allocated == dev && dev->stopping && !client_calls);
        smc_failure = false; assert(!dcp_shutdown(dev, false) && !allocated); cases++;
#endif
#ifdef DART_LIFECYCLE
        for (unsigned which = 1; which <= 3; which++) {
            dcp_dev_t *owner = start(); cleanup_failure = which;
            assert(dcp_shutdown(owner, false) < 0 && allocated == owner);
            assert(owner->quiesced && !owner->rtkit && owner->asc == &token[3]);
            assert(released == which - 1 && power_calls == 1);
            assert((owner->dart_disp != NULL) == (which == 1));
            assert((owner->iovad_dcp != NULL) == (which <= 2));
            assert(owner->dart_dcp == &token[0]);
            /* A transient fake dependency can recover; real DART faults stay latched. */
            cleanup_failure = 0; stage = 0;
            assert(!dcp_shutdown(NULL, false) && !allocated && !active_dcp);
            assert(released == 5 && power_calls == 1); cases++;
        }
#endif
#endif
    }
    printf("DCP owner lifecycle: PASS (%u checks)\n", cases); return 0;
}
#endif

#ifdef TEST_DISPLAY
typedef enum { DCP_QUIESCED, DCP_SLEEP_IF_EXTERNAL, DCP_SLEEP } dcp_shutdown_mode;
static dcp_dev_t object, *dcp;
static dcp_iboot_if_t client, *iboot;
static bool has_dcp, display_is_external, display_is_dptx, shutdown_fail;
static unsigned shutdown_calls, init_calls;
static bool last_sleep;
static u64 fb_size, fb_dva;
static struct { struct { u64 base, stride, height, depth; } video; } cur_boot_args;
static const display_config_t config;
static const display_config_t *display_get_config(void) { has_dcp = true; return &config; }
static dcp_dev_t *dcp_init(const display_config_t *cfg) { assert(cfg); init_calls++; return &object; }
static int display_get_vram(u64 *pa, u64 *size) { *pa = 4096; *size = 4096; return 0; }
static u64 dart_search(dart_dev_t *dart, void *pa) { (void)dart; (void)pa; return 4096; }
static u64 display_map_fb(u64 old, u64 pa, u64 size) { (void)old; (void)pa; (void)size; return 4096; }
#define DART_IS_ERR(x) ((x) == (u64)-1)
static dcp_iboot_if_t *dcp_ib_init(dcp_dev_t *dev) { assert(dev); return &client; }
#ifdef BASELINE
static int dcp_ib_shutdown(dcp_iboot_if_t *p) { assert(p); return 0; }
#endif
static int dcp_shutdown(dcp_dev_t *dev, bool sleep)
{ assert(!dev || dev == &object); shutdown_calls++; last_sleep = sleep; return shutdown_fail ? -1 : 0; }
#define printf diagnostic
#include "display.inc"
#undef printf
int main(int argc, char **argv)
{
    assert(argc == 2); (void)argv;
    has_dcp = true; dcp = &object; iboot = &client; shutdown_fail = true;
#ifdef BASELINE
    display_shutdown(DCP_SLEEP);
    /* Failure must not leave a usable/dangling alias or report implicit success. */
    assert(iboot == NULL && display_start_dcp() < 0);
#else
    assert(display_shutdown(DCP_SLEEP) < 0 && !iboot && dcp == &object);
    assert(display_start_dcp() < 0 && !init_calls && last_sleep); cases++;
    shutdown_fail = false;
    assert(!display_shutdown(DCP_QUIESCED) && !iboot && !dcp && !last_sleep); cases++;
    for (unsigned external = 0; external < 2; external++)
        for (unsigned mode = 0; mode < 3; mode++) {
            dcp = &object; iboot = &client; display_is_external = external;
            assert(!display_shutdown(mode) && !iboot && !dcp);
            assert(last_sleep == (mode == DCP_SLEEP || (mode == DCP_SLEEP_IF_EXTERNAL && external)));
            cases++;
        }
    unsigned before = shutdown_calls;
    assert(display_shutdown(999) < 0 && shutdown_calls == before); cases++;
    shutdown_fail = true;
    assert(display_shutdown(DCP_QUIESCED) < 0); cases++; /* Failed init retained inside DCP. */
#endif
    printf("Display lifecycle: PASS (%u checks)\n", cases); return 0;
}
#endif

#ifdef TEST_RTKIT_FREE
struct buffer { unsigned number; bool owned; };
struct rtkit_dev { struct buffer syslog_bfr, crashlog_bfr, ioreport_bfr; char *name; };
static unsigned failure, frees, buffer_calls;
static rtkit_dev_t *owner;
static bool rtkit_free_buffer(rtkit_dev_t *rtk, struct buffer *buffer)
{ assert(rtk == owner); buffer_calls++; if (failure == buffer->number) return false; buffer->owned = false; return true; }
static void release(void *pointer) { assert(pointer); frees++; free(pointer); }
#define free release
#include "rtkit-free.inc"
#undef free
int main(int argc, char **argv)
{
    assert(argc == 2); (void)argv; (void)diagnostic;
    for (unsigned which = 1; which <= 3; which++) {
        owner = calloc(1, sizeof(*owner)); assert(owner); owner->name = malloc(8); assert(owner->name);
        owner->syslog_bfr = (struct buffer){1, true}; owner->crashlog_bfr = (struct buffer){2, true};
        owner->ioreport_bfr = (struct buffer){3, true}; failure = which; frees = buffer_calls = 0;
#ifdef BASELINE
        rtkit_free(owner); assert(!frees);
#else
        assert(!rtkit_free(owner) && !frees && buffer_calls == which);
        failure = 0; assert(rtkit_free(owner) && frees == 2); cases++;
#endif
    }
    printf("RTKit owner retention: PASS (%u checks)\n", cases); return 0;
}
#endif

#ifdef TEST_HANDOFF
enum { DCP_SLEEP_IF_EXTERNAL };
static struct { void *entry; } next_stage;
static unsigned failures, proxies, handoffs, empty_entry;
static bool persistent;
#ifdef DART_LIFECYCLE
static bool dart_failure, usb_fault, usb_failure;
static unsigned usb_calls, usb_failures;
static bool dart_has_faults(void) { return dart_failure; }
static bool usb_iodev_shutdown(void)
{ usb_calls++; if (usb_failures) { usb_failures--; return false; } return !usb_failure && !usb_fault; }
#endif
#ifdef STORAGE_LIFECYCLE
static unsigned nvme_failures, nvme_calls;
static bool nvme_persistent, select_entry;
static bool nvme_shutdown(void)
{ nvme_calls++; if (nvme_persistent) return false; if (nvme_failures) { nvme_failures--; return false; } return true; }
#endif
static jmp_buf escape;
static int display_shutdown(int mode)
{ assert(mode == DCP_SLEEP_IF_EXTERNAL); if (persistent) return -1; if (failures) { failures--; return -1; } return 0; }
static void uartproxy_run(void *context)
{
    assert(!context); proxies++;
    if (empty_entry) next_stage.entry = NULL;
#ifdef STORAGE_LIFECYCLE
    if (select_entry) {
        assert(!nvme_calls); /* No stage selected: existing NVMe must remain usable. */
        next_stage.entry = (void *)1; select_entry = false;
    }
#endif
    if (proxies == 3) longjmp(escape, 1);
}
static void handoff(void)
{
#define printf diagnostic
#include "handoff.inc"
#undef printf
    assert(next_stage.entry); handoffs++;
}
int main(int argc, char **argv)
{
    assert(argc == 2); (void)argv;
    next_stage.entry = (void *)1; failures = 1;
    handoff(); assert(proxies == 1 && handoffs == 1); cases++;
    proxies = handoffs = 0; persistent = true;
    if (!setjmp(escape)) handoff();
    assert(proxies == 3 && !handoffs); cases++;
    proxies = handoffs = 0; persistent = false; failures = 1; empty_entry = 1;
    if (!setjmp(escape)) handoff();
    assert(proxies == 3 && !handoffs); cases++;
#ifdef STORAGE_LIFECYCLE
    proxies = handoffs = empty_entry = 0; next_stage.entry = (void *)1; nvme_failures = 1;
    handoff(); assert(proxies == 1 && handoffs == 1); cases++;
    proxies = handoffs = 0; nvme_persistent = true;
    if (!setjmp(escape)) handoff();
    assert(proxies == 3 && !handoffs); cases++;
    proxies = handoffs = 0; nvme_persistent = false; failures = nvme_failures = 1;
    handoff(); assert(proxies == 2 && handoffs == 1); cases++;
    proxies = handoffs = 0; nvme_failures = empty_entry = 1;
    if (!setjmp(escape)) handoff();
    assert(proxies == 3 && !handoffs); cases++;
    proxies = handoffs = empty_entry = nvme_failures = nvme_calls = 0;
    next_stage.entry = NULL; select_entry = true;
    handoff(); assert(proxies == 1 && handoffs == 1 && nvme_calls == 1); cases++;
    proxies = handoffs = nvme_calls = 0; next_stage.entry = NULL;
    if (!setjmp(escape)) handoff();
    assert(proxies == 3 && !handoffs && !nvme_calls); cases++;
#endif
#ifdef DART_LIFECYCLE
    for (volatile unsigned which = 0; which < 3; which++) {
        next_stage.entry = (void *)1;
        proxies = handoffs = nvme_calls = usb_calls = 0;
        dart_failure = which == 0; usb_fault = which == 1; usb_failure = which == 2;
        if (!setjmp(escape)) handoff();
        assert(proxies == 3 && !handoffs);
        if (which == 0) assert(!nvme_calls && !usb_calls);
        else assert(nvme_calls == 3 && usb_calls == 3);
        cases++;
    }
    dart_failure = usb_fault = usb_failure = false;
    proxies = handoffs = usb_calls = 0; usb_failures = 1;
    handoff(); assert(proxies == 1 && handoffs == 1 && usb_calls == 2); cases++;
#endif
    printf("Handoff retry/entry guard: PASS (%u checks); HV/proxy ordering checked by runner\n", cases);
    return 0;
}
#endif
