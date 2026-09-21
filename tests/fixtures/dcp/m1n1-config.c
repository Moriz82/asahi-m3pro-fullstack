/* SPDX-License-Identifier: MIT */
/* Complete production selector/init/shutdown; every hardware dependency is fake. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
typedef uint8_t u8;
typedef uint32_t u32;
typedef uint64_t u64;
typedef int dart_dev_t;
typedef int iova_domain_t;
typedef int asc_dev_t;
typedef int rtkit_dev_t;
typedef int afk_epic_t;
typedef int dcp_system_if_t;
typedef int dcp_dpav_if_t;
typedef int dcp_dptx_if_t;
typedef int dptx_phy_t;
#include "types.inc"
#include "names.inc"
static void *adt;
static bool has_dcp, node_present = true;
static const char *board = "J514sAP";
static const display_config_t *active;
static unsigned events, resets, powers, sleeps, quiesces, cases, cleaned_darts;
static unsigned reset_die, failure;
static char reset_name[24];
static int mappings;
static int fake_dart[2], fake_asc, fake_iovad, fake_rtkit, fake_afk;
static bool smc_shutdown(void *smc) __attribute__((unused));
static bool smc_shutdown(void *smc) { assert(!smc); return true; }
enum { V13_5 = 135, V14_7 = 147 };
enum { DART_ERR_UNSUPPORTED_PT_REGION = -2 };
static struct { int version; } os_firmware;
static int diagnostic(const char *format, ...) { (void)format; return 0; }
static bool adt_is_compatible(void *tree, int node, const char *name)
{ assert(tree == adt && node == 0); return !strcmp(board, name); }
static int adt_path_offset(void *tree, const char *path)
{ assert(tree == adt && path[0] == '/'); return node_present ? 10 : -1; }
#define printf diagnostic
#include "display.inc"
#undef printf
static int adt_first_child_offset(void *tree, int node)
{ assert(tree == adt && node == 10); events++; return failure == 1 ? -1 : 11; }
static int get_sid(void *tree, int node, const char *name, u32 *sid)
{ assert(tree == adt && node == 11 && !strcmp(name, "reg")); events++; *sid = 5; return failure == 2 ? -1 : 0; }
#define ADT_GETPROP get_sid
static void *allocate(size_t n, size_t size)
{ assert(n == 1 && size == sizeof(dcp_dev_t)); events++; return failure == 3 ? NULL : calloc(n, size); }
static int pmgr_adt_power_enable(const char *path)
{ assert(!strcmp(path, active->dcp) || !strcmp(path, active->dptx_phy)); events++; powers++; return 0; }
static void mdelay(unsigned delay) { assert(delay == 25); events++; }
static dart_dev_t *dart_init_adt(const char *path, int instance, int sid, bool keep)
{
    assert(instance == 0 && keep); events++;
    if (!strcmp(path, active->dcp_dart)) { assert(sid == 5); return failure == 4 ? NULL : &fake_dart[0]; }
    assert(!strcmp(path, active->disp_dart) && sid == 0);
    return failure == 5 ? NULL : &fake_dart[1];
}
static u64 dart_vm_base(dart_dev_t *dart) { assert(dart == &fake_dart[0]); return 1ULL << 40; }
static int dart_setup_pt_region(dart_dev_t *dart, const char *path, int sid, u64 base)
{
    assert(base == (1ULL << 40)); events++;
    assert((dart == &fake_dart[0] && sid == 5 && !strcmp(path, active->dcp_dart)) ||
           (dart == &fake_dart[1] && sid == 0 && !strcmp(path, active->disp_dart)));
    if (failure == (dart == &fake_dart[0] ? 11U : 12U))
        return DART_ERR_UNSUPPORTED_PT_REGION;
    return failure == (dart == &fake_dart[0] ? 13U : 14U) ? -1 : 0;
}
static iova_domain_t *iovad_init(u64 start, u64 end)
{ assert(start == (1ULL << 40) + 0x10000000 && end == start + 0x10000000); events++; return &fake_iovad; }
static int dcp_create_firmware_mappings(const display_config_t *cfg, dcp_dev_t *dcp)
{ assert(cfg == active && dcp); events++; return mappings; }
static int pmgr_reset(int die, const char *name)
{ events++; resets++; reset_die = die; snprintf(reset_name, sizeof(reset_name), "%s", name); return 0; }
static asc_dev_t *asc_init(const char *path)
{ assert(!strcmp(path, active->dcp)); events++; return failure == 6 ? NULL : &fake_asc; }
static rtkit_dev_t *rtkit_init(const char *name, asc_dev_t *asc, dart_dev_t *dart,
                             iova_domain_t *domain, void *opaque, bool flag)
{ assert(!strcmp(name, "dcp") && asc == &fake_asc && dart == &fake_dart[0] && domain == &fake_iovad && !opaque && !flag); events++; return failure == 7 ? NULL : &fake_rtkit; }
static bool rtkit_boot(rtkit_dev_t *rt) { assert(rt == &fake_rtkit); events++; return failure != 8; }
static afk_epic_t *afk_epic_init(rtkit_dev_t *rt) { assert(rt == &fake_rtkit); events++; return failure == 9 ? NULL : &fake_afk; }
static int dcp_hdmi_dptx_init(dcp_dev_t *dcp, const display_config_t *cfg)
{ assert(dcp && cfg == active); events++; return failure == 10 ? -1 : 0; }
#ifdef DART_LIFECYCLE
static bool dart_is_faulted(dart_dev_t *dart) { return !dart; }
static bool dart_shutdown(dart_dev_t *dart)
{ if (!dart) return true; assert(dart == &fake_dart[0] || dart == &fake_dart[1]); events++; cleaned_darts++; return true; }
static bool iovad_shutdown(iova_domain_t *domain, dart_dev_t *dart)
{ if (!domain) return true; assert(domain == &fake_iovad && dart == &fake_dart[0]); events++; return true; }
#else
static void dart_shutdown(dart_dev_t *dart) { assert(dart == &fake_dart[0] || dart == &fake_dart[1]); events++; cleaned_darts++; }
static void iovad_shutdown(iova_domain_t *domain, dart_dev_t *dart)
{ assert(domain == &fake_iovad && dart == &fake_dart[0]); events++; }
#endif
static bool rtkit_quiesce(rtkit_dev_t *rt) { assert(rt == &fake_rtkit); events++; quiesces++; return true; }
static bool rtkit_free(rtkit_dev_t *rt) { if (!rt) return true; assert(rt == &fake_rtkit); events++; return true; }
static bool rtkit_sleep(rtkit_dev_t *rt) { assert(rt == &fake_rtkit); events++; sleeps++; return true; }
static int afk_epic_shutdown(afk_epic_t *ep) { if (!ep) return 0; assert(ep == &fake_afk); events++; return 0; }
static int dcp_system_shutdown(dcp_system_if_t *ep) { assert(!ep); events++; return 0; }
static int dcp_dptx_shutdown(dcp_dptx_if_t *ep) { assert(!ep); events++; return 0; }
static int dcp_dpav_shutdown(dcp_dpav_if_t *ep) { assert(!ep); events++; return 0; }
#ifdef DCP_LIFECYCLE_V2
static int dcp_ib_shutdown(struct dcp_iboot_if *ep) { assert(!ep); return 0; }
static void asc_free(asc_dev_t *asc) { assert(asc == &fake_asc); events++; }
#endif
int dcp_shutdown(dcp_dev_t *dcp, bool sleep);
#define calloc allocate
#define printf diagnostic
#include "lifecycle.inc"
#undef printf
#undef calloc

static void reset_fixture(const display_config_t *cfg)
{
#ifdef DCP_LIFECYCLE_V2
    if (active_dcp) {
        assert(active_dcp->stopping && !active_dcp->rtkit);
        /* End this fake hardware epoch. Production must retain these owners
         * until an independently safe reset, not silently reinitialize them. */
        free(active_dcp);
        active_dcp = NULL;
    }
#endif
    active = cfg; failure = events = resets = powers = sleeps = quiesces = cleaned_darts = 0;
    mappings = 1; os_firmware.version = V13_5; reset_name[0] = 0;
    node_present = true; cases++;
}
static void check_target(void)
{
    board = "J514sAP"; node_present = true;
    const display_config_t *cfg = display_get_config();
    assert(cfg && has_dcp && !strcmp(cfg->pmgr_dev, "DISP_CPU"));
    assert(!strcmp(cfg->dcp, "/arm-io/dcp") && !strcmp(cfg->dcp_alias, "dcp"));
    assert(!strcmp(cfg->dcp_dart, "/arm-io/dart-dcp") && !strcmp(cfg->disp_dart, "/arm-io/dart-disp0"));
    assert(!cfg->dptx_phy[0] && !cfg->dp2hdmi_gpio[0] && !cfg->die && !cfg->dcp_index && !cfg->num_dptxports);
    cases++;
}
static void run_internal(void)
{
    const display_config_t cfg = {
        .dcp = "/arm-io/dcp", .dcp_dart = "/arm-io/dart-dcp",
        .disp_dart = "/arm-io/dart-disp0", .dcp_alias = "dcp",
        .pmgr_dev = "DISP_CPU", .die = 2,
    };
    reset_fixture(&cfg); os_firmware.version = V14_7;
    /* Poison previous external state to catch stale cross-device reset routing. */
    strcpy(dcp_pmgr_dev, "DISPEXT0_CPU0"); dcp_die = 1;
    dcp_dev_t *dcp = dcp_init(&cfg);
    assert(dcp && !powers && resets == 1);
    assert(!strcmp(reset_name, "DISP_CPU") && reset_die == 2);
    assert(dcp_shutdown(dcp, true) == 0 && resets == 2 && sleeps == 1 && !quiesces);
    assert(!strcmp(reset_name, "DISP_CPU") && reset_die == 2 && cleaned_darts == 2);
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "j514s")) { check_target(); return 0; }
    if (!strcmp(argv[1], "internal")) { run_internal(); return 0; }
    assert(!strcmp(argv[1], "all"));
    check_target(); run_internal();
    const char *boards[] = {"J473AP", "J474sAP", "J475cAP", "J180dAP", "J475dAP", "J516sAP", "J314sAP", "unknown"};
    const display_config_t *expected[] = {&display_config_m2, &display_config_m2_pro_max, &display_config_m2_pro_max,
        &display_config_m2_ultra, &display_config_m2_ultra, &display_config_m1, &display_config_m1, &display_config_m1};
    for (unsigned i = 0; i < sizeof(boards)/sizeof(*boards); i++) {
        board = boards[i]; node_present = true;
        assert(display_get_config() == expected[i] && has_dcp); cases++;
        node_present = false; assert(!display_get_config() && !has_dcp); cases++;
    }
    board = "J514sAP"; node_present = false; assert(!display_get_config() && !has_dcp); cases++;
    /* J473's duplicate-field cleanup must preserve DPTX gating in both modes. */
    board = "J473AP"; node_present = true;
    const display_config_t *j473 = display_get_config();
    assert(j473 && !strcmp(j473->dptx_phy, "/arm-io/dptx-phy") &&
           !strcmp(j473->dp2hdmi_gpio, "/arm-io/dp2hdmi-gpio") && j473->num_dptxports == 2);
    reset_fixture(j473);
    dcp_dev_t *j473_dcp = dcp_init(j473);
    assert(j473_dcp && powers == 2 && resets == 1 && !reset_die);
    assert(!strcmp(reset_name, USE_DCPEXT ? "DISPEXT_CPU0" : "DISP0_CPU0"));
    assert(!dcp_shutdown(j473_dcp, false));
    reset_fixture(j473); os_firmware.version = V14_7;
    assert(!dcp_init(j473) && !events);
    const display_config_t cfg = {
        .dcp = "/arm-io/dcp", .dcp_dart = "/arm-io/dart-dcp",
        .disp_dart = "/arm-io/dart-disp0", .dcp_alias = "dcp",
        .pmgr_dev = "DISP_CPU",
    };
    for (int created = -1; created <= 1; created++) for (unsigned sleep = 0; sleep <= 1; sleep++) {
        reset_fixture(&cfg); mappings = created;
        dcp_dev_t *dcp = dcp_init(&cfg);
        if (created < 0) {
#ifdef DCP_LIFECYCLE_V2
            assert(!dcp && !resets && !cleaned_darts && active_dcp);
#else
            assert(!dcp && !resets && cleaned_darts == 2);
#endif
            continue;
        }
        assert(dcp && resets == (unsigned)created && !powers);
        assert(dcp_shutdown(dcp, sleep) == 0);
        assert(resets == (unsigned)created + sleep && sleeps == sleep && quiesces == !sleep);
        if (resets) assert(!strcmp(reset_name, "DISP_CPU") && reset_die == 0);
    }
    for (unsigned stage = 1; stage <= 9; stage++) {
        reset_fixture(&cfg); failure = stage;
        assert(!dcp_init(&cfg));
        assert(resets == (stage >= 6 ? 1U : 0U));
#ifdef DCP_LIFECYCLE_V2
        assert(cleaned_darts == (stage <= 7 ? 0U : 2U));
        if (stage >= 5 && stage <= 7) assert(active_dcp);
#else
        assert(cleaned_darts == (stage <= 4 ? 0U : stage == 5 ? 1U : 2U));
#endif
    }
    for (unsigned stage = 11; stage <= 12; stage++) {
        reset_fixture(&cfg); failure = stage;
        assert(!dcp_init(&cfg));
#ifdef DCP_LIFECYCLE_V2
        assert(!resets && !quiesces && !powers && !cleaned_darts && active_dcp);
#else
        assert(!resets && !quiesces && !powers && cleaned_darts == stage - 10);
#endif
    }
    for (unsigned stage = 13; stage <= 14; stage++) {
        reset_fixture(&cfg); failure = stage;
        dcp_dev_t *dcp = dcp_init(&cfg);
        assert(dcp && resets == 1); /* Legacy preallocation failures retain their fallback. */
        assert(!dcp_shutdown(dcp, false) && cleaned_darts == 2);
    }
    {
    const display_config_t cfg = display_config_m2_ultra;
    reset_fixture(&cfg);
    dcp_dev_t *dcp = dcp_init(&cfg);
    assert(dcp && powers == 2 && resets == 1 && reset_die == 1 && !strcmp(reset_name, "DISPEXT0_CPU0"));
    assert(!dcp_shutdown(dcp, false) && quiesces == 1);
    reset_fixture(&cfg); failure = 10; assert(!dcp_init(&cfg) && powers == 2 && cleaned_darts == 2 && quiesces == 1);
    reset_fixture(&cfg); os_firmware.version = V14_7;
    strcpy(dcp_pmgr_dev, "sentinel"); dcp_die = 7;
    assert(!dcp_init(&cfg) && !events && !strcmp(dcp_pmgr_dev, "sentinel") && dcp_die == 7);
    reset_fixture(&cfg); assert(!dcp_init(NULL) && !events);
    }
    for (unsigned length = 0; length <= sizeof(cfg.pmgr_dev); length++) {
        const display_config_t cfg = varied_names[length];
        reset_fixture(&cfg);
        dcp_dev_t *dcp = dcp_init(&cfg);
        if (!length || length >= sizeof(dcp_pmgr_dev)) assert(!dcp && !events);
        else { assert(dcp && strlen(reset_name) == length); assert(!dcp_shutdown(dcp, false)); }
    }
    printf("{\"target\":\"DISP_CPU\",\"sid\":5,\"cases\":%u}\n", cases);
    return 0;
}
