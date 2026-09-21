/* SPDX-License-Identifier: MIT */
/* Actual dt_set_display and mapping arrays, real libfdt. Hardware/services are
 * recorded fakes. This tests alias selection/dispatch, not table publication. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libfdt.h"

#ifdef NDEBUG
#error "Assertions are part of this test"
#endif
typedef uint32_t u32;
#define ARRAY_SIZE(x) (sizeof(x) / sizeof((x)[0]))
#define V13_5 1
static struct { int version; } os_firmware;
typedef struct { const char *dcp_alias; } display_config_t;
static const display_config_t config = {"configured-dcp"};
static void *dt;
static unsigned locks, reservations, internal, external_firmware, vram, cases;
static int fail_reservation, vram_result;
static bool custom_config;
static const char *expected_alias;
static void quiet(const char *fmt, ...) { (void)fmt; }
#define printf(...) quiet(__VA_ARGS__)

#include "mapping-struct.inc"
#include "mapping-arrays.inc"

static void dart_lock_adt(const char *path, unsigned index)
{
    assert(!strcmp(path, "/arm-io/dart-disp0") && index == 0);
    locks++;
}
static int dt_carveout_reserved_regions(const char *dcp, const char *display,
                                        const char *piodma, struct disp_mapping *maps, u32 count)
{
    assert(locks == 1 && maps && count > 0);
    reservations++;
    if (!strcmp(dcp, "dcp")) {
        internal++;
        assert(!strcmp(display, "disp0"));
        assert(!strcmp(piodma, expected_alias) && "canonical PIODMA alias selection");
        const char *path = fdt_get_alias(dt, piodma);
        if (path) assert(fdt_path_offset(dt, path) >= 0);
        /* Missing aliases retain upstream helper policy; not inferred here. */
    } else {
        assert(!strncmp(dcp, "dcpext", 6) && !display && !piodma);
    }
    return (int)reservations == fail_reservation ? -17 : 0;
}
static int dt_reserve_dcpext_firmware(void)
{ external_firmware++; return -29; /* Existing caller intentionally ignores it. */ }
static const display_config_t *display_get_config(void)
{ return custom_config ? &config : NULL; }
static int dt_vram_reserved_region(const char *dcp, const char *display)
{
    assert(!strcmp(dcp, custom_config ? "configured-dcp" : "dcp"));
    assert(!strcmp(display, "disp0"));
    vram++;
    return vram_result;
}
#include "display.inc"
#undef printf

static void setup(const char *compatible, unsigned aliases)
{
    assert(!fdt_create_empty_tree(dt, 8192));
    assert(!fdt_setprop_string(dt, 0, "compatible", compatible));
    assert(fdt_add_subnode(dt, 0, "canonical-piodma") >= 0);
    assert(fdt_add_subnode(dt, 0, "legacy-piodma") >= 0);
    int node = fdt_add_subnode(dt, 0, "aliases");
    assert(node >= 0);
    if (aliases & 1)
        assert(!fdt_setprop_string(dt, node, "disp0-piodma", "/canonical-piodma"));
    if (aliases & 2)
        assert(!fdt_setprop_string(dt, node, "disp0_piodma", "/legacy-piodma"));
    expected_alias = aliases & 2 ? "disp0_piodma" : "disp0-piodma";
    locks = reservations = internal = external_firmware = vram = 0;
    fail_reservation = vram_result = 0;
}

int main(int argc, char **argv)
{
    static unsigned char tree[8192], before[8192];
    dt = tree;
    const char *soc[] = {"apple,t8103", "apple,t8112", "apple,t6000", "apple,t6001",
                         "apple,t6002", "apple,t6020", "apple,t6021", "apple,t6022",
                         "apple,t6030"};
    bool baseline = argc == 2 && !strcmp(argv[1], "baseline");
    for (unsigned chip = 0; chip < ARRAY_SIZE(soc); chip++) {
        for (unsigned aliases = 0; aliases < 4; aliases++) {
            for (unsigned firmware = 0; firmware < 2; firmware++) {
                for (unsigned selected = 0; selected < 2; selected++) {
                    if (baseline && (chip != 0 || aliases != 1 || firmware || selected)) continue;
                    setup(soc[chip], aliases);
                    memcpy(before, tree, sizeof(tree));
                    os_firmware.version = firmware;
                    custom_config = selected;
                    assert(!dt_set_display());
                    assert(locks == 1 && !memcmp(before, tree, sizeof(tree)));
                    assert(internal == (chip < 7));
                    assert(vram == (chip < 8));
                    unsigned expected = chip == 0 ? 2 : chip == 7 || chip == 8 ? 0 :
                                        (chip >= 2 && chip <= 4 && firmware) ? 9 : 1;
                    assert(reservations == expected);
                    assert(external_firmware == (chip == 1 || (chip >= 5 && chip <= 7)));
                    cases++;
                    if (chip < 8) {
                        setup(soc[chip], aliases); vram_result = -33;
                        assert(dt_set_display() == -33 && vram == 1);
                        cases++;
                    }
                    for (unsigned failure = 1; failure <= expected; failure++) {
                        setup(soc[chip], aliases); fail_reservation = failure;
                        assert(dt_set_display() == -17 && reservations == failure && !vram);
                        cases++;
                    }
                }
            }
        }
    }
    if (argc == 2 && !baseline) {
        FILE *file = fopen(argv[1], "rb"); assert(file);
        assert(!fseek(file, 0, SEEK_END)); long size = ftell(file);
        assert(size > 0 && size < 4 * 1024 * 1024 && !fseek(file, 0, SEEK_SET));
        void *bytes = malloc((size_t)size), *saved = malloc((size_t)size);
        assert(bytes && saved && fread(bytes, 1, (size_t)size, file) == (size_t)size);
        assert(!fclose(file)); memcpy(saved, bytes, (size_t)size); dt = bytes;
        assert(!fdt_check_header(dt) && !fdt_node_check_compatible(dt, 0, "apple,j514s"));
        const char *alias = fdt_get_alias(dt, "disp0-piodma");
        assert(alias && fdt_path_offset(dt, alias) >= 0 && !fdt_get_alias(dt, "disp0_piodma"));
        locks = reservations = internal = external_firmware = vram = 0;
        assert(!dt_set_display() && locks == 1 && !reservations && !vram && !external_firmware);
        assert(!memcmp(saved, bytes, (size_t)size));
        free(saved); free(bytes); cases++;
    }
    printf("{\"alias_dispatch_cases\":%u,\"real_libfdt\":true,\"hardware_access\":false}\n", cases);
    return 0;
}
