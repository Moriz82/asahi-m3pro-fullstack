/* SPDX-License-Identifier: MIT */
/* Real libfdt and loader helper; all ADT API calls serve in-memory metadata. */
#include <assert.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libfdt.h"
typedef uint32_t u32;
#define V14_7 147
#define bail(...) return -1
static void *dt, *adt;
static struct { int version; } os_firmware;
static u32 ids[2], freq[256], kinds[256], ids_len, freq_len, kinds_len;
static bool root_ok, arm_ok, disp_ok, have_ids, have_freq, have_kinds;
static int missing_node;
static unsigned cases;
#include "inputs.inc"

static int adt_path_offset(const void *tree, const char *path)
{
    assert(tree == adt);
    int node = !strcmp(path, "/arm-io") ? 1 : !strcmp(path, "/arm-io/disp0") ? 2 : -1;
    assert(node > 0); /* /arm-io/dcp is not the display clock provider. */
    return node == missing_node ? -1 : node;
}
static bool adt_is_compatible(const void *tree, int node, const char *name)
{
    assert(tree == adt);
    if (node == 0) { assert(!strcmp(name,"J514sAP") || !strcmp(name,"Mac15,6")); return root_ok; }
    if (node == 1) { assert(!strcmp(name,"arm-io,t6030")); return arm_ok; }
    assert(node == 2 && !strcmp(name,"disp0,t6030")); return disp_ok;
}
static const void *adt_getprop(const void *tree, int node, const char *name, u32 *len)
{
    assert(tree == adt);
    if (!strcmp(name,"clock-ids")) { assert(node == 2); *len=ids_len; return have_ids ? ids : NULL; }
    assert(node == 1);
    if (!strcmp(name,"clock-frequencies")) { *len=freq_len; return have_freq ? freq : NULL; }
    assert(!strcmp(name,"clock-frequencies-nclk")); *len=kinds_len; return have_kinds ? kinds : NULL;
}
#include "helper.inc"

static void metadata(void)
{
    ids[0]=348; ids[1]=412; ids_len=sizeof(ids); freq_len=kinds_len=176*4;
    root_ok=arm_ok=disp_ok=have_ids=have_freq=have_kinds=true;
    missing_node=0; os_firmware.version=V14_7;
    for (unsigned i=0; i<256; i++) { freq[i]=100000000+i*1000000; kinds[i]=i%4; }
}
static int node(const char *path) { int n=fdt_path_offset(dt,path); assert(n>=0); return n; }
static void set32(const char *path, const char *name, u32 value)
{ assert(!fdt_setprop_u32(dt,node(path),name,value)); }
static void setstr(const char *path, const char *name, const char *value)
{ assert(!fdt_setprop_string(dt,node(path),name,value)); }
static void disabled(void)
{
    const char *paths[]={"/soc/dcp@28ec00000", "/soc/display-subsystem", "/soc/mbox@28ec08000",
        "/soc/iommu@28d304000", "/soc/iommu@28d30c000", "/dcp-pixel-clock", "/dcp-video-clock"};
    for (unsigned i=0; i<sizeof(paths)/sizeof(paths[0]); i++) {
        int len; const char *s=fdt_getprop(dt,node(paths[i]),"status",&len);
        assert(s && len==9 && !memcmp(s,"disabled",9));
    }
}
static void unchanged_failure(size_t size)
{
    void *copy=malloc(size); assert(copy); memcpy(copy,dt,size);
    assert(dt_set_display_clocks()<0 && !memcmp(copy,dt,size));
    free(copy); cases++;
}
static void success(size_t size, u32 pixel, u32 video)
{
    void *expected=malloc(size); assert(expected); memcpy(expected,dt,size);
    assert(!fdt_setprop_inplace_u32(expected,fdt_path_offset(expected,"/dcp-pixel-clock"),"clock-frequency",pixel));
    assert(!fdt_setprop_inplace_u32(expected,fdt_path_offset(expected,"/dcp-video-clock"),"clock-frequency",video));
    assert(!dt_set_display_clocks() && !memcmp(expected,dt,size));
    disabled(); free(expected); cases++;
}

int main(int argc, char **argv)
{
    assert(argc==2);
    FILE *file=fopen(argv[1],"rb"); assert(file);
    assert(!fseek(file,0,SEEK_END)); long file_size=ftell(file); assert(file_size>0);
    rewind(file); void *input=malloc((size_t)file_size); assert(input);
    assert(fread(input,1,(size_t)file_size,file)==(size_t)file_size); fclose(file);
    assert(!fdt_check_header(input)); size_t size=(size_t)file_size+65536;
    dt=calloc(1,size); assert(dt); assert(!fdt_open_into(input,dt,(int)size));
    set32("/dcp-pixel-clock","clock-frequency",17);
    set32("/dcp-video-clock","clock-frequency",19);
    void *original=malloc(size); assert(original); memcpy(original,dt,size);
    disabled();
    const u32 lengths[]={1,92,93,156,157,176};
    for (unsigned i=0; i<sizeof(lengths)/sizeof(lengths[0]); i++) {
        memcpy(dt,original,size); metadata(); freq_len=kinds_len=lengths[i]*4;
        success(size,lengths[i]>92 ? 192000000 : 0,lengths[i]>156 ? 256000000 : 0);
    }
    metadata(); freq[92]=0; freq[156]=UINT32_MAX; success(size,0,UINT32_MAX);
    /* Repeated publication reads new values, not a cached first result. */
    freq[92]=27; freq[156]=31; success(size,27,31);
    for (unsigned fault=0; fault<34; fault++) {
        memcpy(dt,original,size); metadata();
        const char *dcp="/soc/dcp@28ec00000", *pixel="/dcp-pixel-clock", *video="/dcp-video-clock";
        switch (fault) {
        case 0: os_firmware.version=0; break;
        case 1: root_ok=false; break;
        case 2: missing_node=1; break;
        case 3: missing_node=2; break;
        case 4: arm_ok=false; break;
        case 5: disp_ok=false; break;
        case 6: have_ids=false; break;
        case 7: ids_len=4; break;
        case 8: ids[0]--; break;
        case 9: ids[1]++; break;
        case 10: have_freq=false; break;
        case 11: have_kinds=false; break;
        case 12: freq_len=kinds_len=0; break;
        case 13: freq_len=kinds_len=3; break;
        case 14: kinds_len--; break;
        case 15: kinds[175]=4; break;
        case 16: setstr(dcp,"compatible","wrong"); break;
        case 17: assert(!fdt_delprop(dt,node(dcp),"clock-names")); break;
        case 18: assert(!fdt_setprop(dt,node(dcp),"clock-names","video\0pixel",12)); break;
        case 19: set32(dcp,"clocks",fdt_get_phandle(dt,node(pixel))); break;
        case 20: { fdt32_t refs[2]={cpu_to_fdt32(fdt_get_phandle(dt,node(pixel))),cpu_to_fdt32(fdt_get_phandle(dt,node(pixel)))};
                   assert(!fdt_setprop(dt,node(dcp),"clocks",refs,sizeof(refs))); break; }
        case 21: { fdt32_t refs[2]={cpu_to_fdt32(0x7fffffff),cpu_to_fdt32(fdt_get_phandle(dt,node(video)))};
                   assert(!fdt_setprop(dt,node(dcp),"clocks",refs,sizeof(refs))); break; }
        case 22: setstr(pixel,"compatible","wrong"); break;
        case 23: set32(pixel,"#clock-cells",1); break;
        case 24: assert(!fdt_delprop(dt,node(pixel),"clock-frequency")); break;
        case 25: assert(!fdt_setprop_u64(dt,node(pixel),"clock-frequency",0)); break;
        case 26: setstr(dcp,"status","okay"); break;
        case 27: setstr(pixel,"status","okay"); break;
        case 28: assert(!fdt_delprop(dt,node(video),"clock-frequency")); break;
        case 29: assert(!fdt_setprop_u64(dt,node(video),"clock-frequency",0)); break;
        case 30: set32(video,"#clock-cells",1); break;
        case 31: setstr(video,"status","okay"); break;
        case 32: setstr("/","compatible","apple,j514s"); break;
        case 33: assert(!fdt_delprop(dt,node(dcp),"clocks")); break;
        }
        unchanged_failure(size);
    }
    memcpy(dt,original,size); metadata();
    assert(sizeof(template_freq)<=sizeof(freq)); memcpy(freq,template_freq,sizeof(template_freq));
    freq_len=sizeof(template_freq); have_kinds=false;
    unchanged_failure(size);
    memcpy(dt,original,size); metadata();
    assert(sizeof(recorded_freq)==sizeof(recorded_kinds) && sizeof(recorded_freq)<=sizeof(freq));
    memcpy(freq,recorded_freq,sizeof(recorded_freq)); memcpy(kinds,recorded_kinds,sizeof(recorded_kinds));
    freq_len=kinds_len=sizeof(recorded_freq);
    success(size,712000000,0);
    int len;
    const fdt32_t *value=fdt_getprop(dt,node("/dcp-pixel-clock"),"clock-frequency",&len);
    assert(value && len==4); u32 published_pixel=fdt32_to_cpu(*value);
    value=fdt_getprop(dt,node("/dcp-video-clock"),"clock-frequency",&len);
    assert(value && len==4); u32 published_video=fdt32_to_cpu(*value);
    for (unsigned legacy=0; legacy<2; legacy++) {
        memcpy(dt,original,size); metadata(); os_firmware.version=0;
        if (legacy) assert(!fdt_delprop(dt,node("/aliases"),"dcp"));
        else setstr("/","compatible","apple,j516s");
        void *copy=malloc(size); assert(copy); memcpy(copy,dt,size);
        assert(!dt_set_display_clocks() && !memcmp(copy,dt,size));
        free(copy); cases++;
    }
    printf("{\"cases\":%u,\"recorded_fixture_rates\":[%u,%u],\"all_hardware_nodes_disabled\":true}\n",cases,published_pixel,published_video);
    free(original); free(dt); free(input);
    return 0;
}
