/* SPDX-License-Identifier: MIT */
/* Complete extracted production functions with fake dependencies, no devices. */
#include <assert.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"
#undef printf
static int diagnostic(const char *format, ...) __attribute__((unused));
static int diagnostic(const char *format, ...) { (void)format; return 0; }

#ifdef TEST_PMGR
#include "pmgr.h"
static const struct pmgr_device { char name[16]; } pmgr_devices[] = {{"ANS"}, {"ANS2"}};
static unsigned pmgr_devices_len = 2, resets;
static bool reset_error;
static int pmgr_reset_device(int die, const struct pmgr_device *device)
{ assert(die == 1 && (device == &pmgr_devices[0] || device == &pmgr_devices[1])); resets++; return reset_error ? -1 : 0; }
#include "integration.inc"
int main(void)
{
    assert(pmgr_reset(1, "absent") == -2 && !resets);
    assert(!pmgr_reset(1, "ANS") && resets == 1);
    assert(!pmgr_reset(1, "ANS2") && resets == 2);
    reset_error = true; assert(pmgr_reset(1, "ANS") == -1 && resets == 3);
    pmgr_devices_len = 0; assert(pmgr_reset(1, "ANS2") == -2 && resets == 3);
    puts("PMGR reset result contract: PASS (5 scenarios)");
}
#endif

#ifdef TEST_HDMI
#include "adt.h"
#include "dcp.h"
#include "smc.h"
#include "dcp/dptx_phy.h"
void *adt;
static unsigned failure, writes, shutdowns, phys;
static unsigned gpio_records[8];
int adt_path_offset(const void *tree, const char *path)
{ (void)tree; (void)path; return failure == 5 ? -1 : 1; }
int adt_getprop_copy(const void *tree, int node, const char *name, void *out, size_t size)
{
    (void)tree; assert(node == 1 && size == 16); memset(out, 0, size);
    u32 gpio = !strcmp(name, "function-dp2hdmi_pwr_en") ? 0x20 : 0x21;
    memcpy((u8 *)out + 8, &gpio, sizeof(gpio)); return 0;
}
smc_dev_t *smc_init(void) { return failure == 1 ? NULL : (void *)gpio_records; }
int smc_write_u32(smc_dev_t *smc, u32 key, u32 value)
{ assert(smc == (void *)gpio_records && key == 0x20 + writes && value == 0x800001); writes++; return failure == writes + 1 ? -1 : 0; }
#ifdef BASELINE
void smc_shutdown(smc_dev_t *smc) { assert(smc == (void *)gpio_records); shutdowns++; }
#else
bool smc_shutdown(smc_dev_t *smc) { assert(smc == (void *)gpio_records); shutdowns++; return failure != 4; }
#endif
dptx_phy_t *dptx_phy_init(const char *path, u32 index)
{ assert(path[0] == '/' && index == 1); phys++; return (void *)gpio_records; }
dcp_dpav_if_t *dcp_dpav_init(dcp_dev_t *dcp) { (void)dcp; return (void *)gpio_records; }
dcp_dptx_if_t *dcp_dptx_init(dcp_dev_t *dcp, u32 ports)
{ assert(dcp->die == 1 && ports == 2); return (void *)gpio_records; }
#define printf diagnostic
#include "integration.inc"
#undef printf
int main(void)
{
    display_config_t cfg = {.dp2hdmi_gpio = "/gpio", .dptx_phy = "/phy", .dcp_index = 1, .die = 1, .num_dptxports = 2};
    for (failure = 0; failure < 6; failure++) {
        dcp_dev_t dcp = {0}; writes = shutdowns = phys = 0;
        int result = dcp_hdmi_dptx_init(&dcp, &cfg);
        if (!failure) assert(!result && writes == 2 && shutdowns == 1 && phys == 1);
        else {
            assert(result < 0 && !phys);
            if (failure == 1 || failure == 5) assert(!writes && !shutdowns);
            else assert(writes == (failure == 2 ? 1U : 2U) && shutdowns == 1);
        }
    }
    puts("HDMI SMC failure propagation: PASS (6 scenarios)");
}
#endif

#ifdef TEST_CHAINLOAD
#include "nvme.h"
static bool init_ok, stop_ok;
static int load_result;
static size_t load_size;
static unsigned loads, stops, handoffs, frees;
static void *loaded;
bool nvme_init(void) { return init_ok; }
#ifdef BASELINE
void nvme_shutdown(void) { stops++; }
#else
bool nvme_shutdown(void) { stops++; return stop_ok; }
#endif
static int rust_load_image(const char *spec, void **image, size_t *size)
{
    assert(!strcmp(spec, "test")); loads++;
    if (load_result) return -17;
    loaded = load_size ? malloc(load_size) : (void *)1;
    assert(loaded); *image = loaded; *size = load_size; return 0;
}
static int chainload_image(void *image, size_t size, char **vars, size_t count)
{ assert(image == loaded && size == load_size && !vars && !count); handoffs++; return 23; }
static void release(void *pointer) __attribute__((unused));
static void release(void *pointer)
{ assert(pointer == loaded && load_size && !frees); free(pointer); loaded = NULL; frees++; }
#define free release
#define printf diagnostic
#include "integration.inc"
#undef printf
#undef free
int main(void)
{
    for (unsigned scenario = 0; scenario < 6; scenario++) {
        init_ok = scenario != 0; stop_ok = scenario == 1 || scenario == 4;
        load_result = scenario == 1 || scenario == 3 ? -17 : 0;
        load_size = scenario == 5 ? 0 : 32;
        loads = stops = handoffs = frees = 0; loaded = NULL;
        int result = chainload_load("test", NULL, 0);
        if (!init_ok) assert(result == -1 && !loads && !stops && !handoffs);
        else if (!stop_ok) {
            assert(result == -1 && stops == 1 && !handoffs);
            assert(frees == (!load_result && load_size ? 1U : 0U));
        } else if (load_result) assert(result == load_result && !handoffs && !frees);
        else { assert(result == 23 && handoffs == 1 && !frees); free(loaded); }
    }
    puts("Chainload shutdown gate: PASS (6 scenarios)");
}
#endif
