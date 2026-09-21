/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "utils.h"
#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif
#ifndef M1N1_DART_SOURCE
#error "Define actual dart.c path"
#endif

static void forbidden_barrier(void) { assert(!"hardware barrier executed"); }
static void forbidden_write(u64 a,u32 v) { (void)a;(void)v; assert(!"MMIO write executed"); }
static int forbidden_poll(u64 a,u32 m,u32 v,u32 t)
{ (void)a;(void)m;(void)v;(void)t; assert(!"MMIO poll executed"); return -1; }
#undef dma_wmb
#define dma_wmb forbidden_barrier
#define write32 forbidden_write
#define poll32 forbidden_poll
#define dart_search source_dart_search
#define dart_translate source_dart_translate
#include M1N1_DART_SOURCE
#undef dart_search
#undef dart_translate
static unsigned searches, translations, diagnostics, cases;
static u64 dart_search(dart_dev_t *dart,void *paddr)
{ searches++; return source_dart_search(dart,paddr); }
static void *dart_translate(dart_dev_t *dart,uintptr_t iova)
{ translations++; return source_dart_translate(dart,iova); }
#include "mapping.inc"
#undef printf
int debug_printf(const char *format,...)
{ (void)format; diagnostics++; return 0; }

static u64 roots[4][2048] __attribute__((aligned(16384)));
static u64 leaves[4][2048] __attribute__((aligned(16384)));
static u64 saved_roots[4][2048], saved_leaves[4][2048];
static dart_dev_t dart;
static const u64 physical=0x40000000;
static u64 base;
static u64 pte(u64 address)
{
    u64 value=FIELD_PREP(dart.params->offset_mask,address>>DART_PTE_OFFSET_SHIFT);
    assert((FIELD_GET(dart.params->offset_mask,value)<<DART_PTE_OFFSET_SHIFT)==address);
    return value | dart.params->pte_flags;
}
static void setup(const struct dart_params *params,unsigned root,unsigned index,unsigned slot,unsigned pages)
{
    memset(roots,0,sizeof(roots)); memset(leaves,0,sizeof(leaves)); memset(&dart,0,sizeof(dart));
    dart.params=params; base=((u64)root<<36)|((u64)index<<25)|((u64)slot<<14);
    unsigned leaf=0; u64 previous=UINT64_MAX;
    for (unsigned i=0;i<pages;i++) {
        u64 address=base+(u64)i*SZ_16K;
        unsigned r=address>>36, a=(address>>25)&2047, b=(address>>14)&2047;
        assert(r<(unsigned)params->ttbr_count);
        if ((address>>25)!=previous) { if (previous!=UINT64_MAX) leaf++; previous=address>>25; }
        assert(leaf<4);
        dart.l1[r]=roots[r]; roots[r][a]=pte((u64)leaves[leaf]); leaves[leaf][b]=pte(physical+(u64)i*SZ_16K);
    }
    searches=translations=diagnostics=0;
}
static u64 *entry(unsigned page)
{
    u64 address=base+(u64)page*SZ_16K;
    u64 *root=dart.l1[address>>36];
    u64 *leaf=(void *)(FIELD_GET(dart.params->offset_mask,root[(address>>25)&2047])<<DART_PTE_OFFSET_SHIFT);
    return &leaf[(address>>14)&2047];
}
static u64 check(u64 paddr,size_t size)
{
    dart_dev_t before=dart;
    memcpy(saved_roots,roots,sizeof(roots)); memcpy(saved_leaves,leaves,sizeof(leaves));
    u64 result=dart_get_mapping(&dart,"fixture",paddr,size);
    assert(!memcmp(&before,&dart,sizeof(dart)));
    assert(!memcmp(saved_roots,roots,sizeof(roots)) && !memcmp(saved_leaves,leaves,sizeof(leaves)));
    cases++; return result;
}
static void negative(const char *mode)
{
    setup(&dart_t8110,0,0,0,4);
    if (!strcmp(mode,"hole")) {
        *entry(1)=0; assert(DART_IS_ERR(check(physical,4*SZ_16K)));
    } else if (!strcmp(mode,"remapped-middle")) {
        *entry(1)=pte(physical+8*SZ_16K); assert(DART_IS_ERR(check(physical,4*SZ_16K)));
    } else if (!strcmp(mode,"zero-length")) {
        assert(DART_IS_ERR(check(physical+SZ_16K,0)));
    } else if (!strcmp(mode,"extent-overflow")) {
        assert(DART_IS_ERR(check(physical+SZ_16K,SIZE_MAX)));
    } else if (!strcmp(mode,"iova-alias")) {
        assert(source_dart_translate(&dart,1ULL<<38)==NULL); cases++;
    } else assert(!"unknown negative mode");
}
int main(int argc,char **argv)
{
    assert(argc==2);
    if (strcmp(argv[1],"all")) negative(argv[1]);
    else {
        const struct dart_params *formats[]={&dart_t8020,&dart_t6000,&dart_t8110};
        const unsigned indices[]={0,1,2047};
        const unsigned slots[]={0,1,2046};
        for (unsigned f=0;f<3;f++) {
            for (unsigned r=0;r<(unsigned)formats[f]->ttbr_count;r++) {
                for (unsigned a=0;a<3;a++) for (unsigned b=0;b<3;b++) {
                    unsigned pages=indices[a]==2047 && slots[b]==2046 ? 2 : 4;
                    setup(formats[f],r,indices[a],slots[b],pages);
                    for (unsigned n=1;n<=pages;n++) {
                        const unsigned trims[]={0,1,SZ_16K-1};
                        for (unsigned t=0;t<3;t++) {
                            u64 size=(u64)n*SZ_16K-trims[t];
                            assert(check(physical,size)==base);
                        }
                    }
                    for (unsigned page=0;page<pages;page++) {
                        u64 saved=*entry(page); *entry(page)=0;
                        assert(DART_IS_ERR(check(physical,pages*SZ_16K))); *entry(page)=saved;
                        *entry(page)=pte(physical+(16+page)*SZ_16K);
                        assert(DART_IS_ERR(check(physical,pages*SZ_16K))); *entry(page)=saved;
                    }
                    unsigned old_searches=searches,old_translations=translations;
                    assert(DART_IS_ERR(check(physical,0)));
                    assert(DART_IS_ERR(check(physical,SIZE_MAX)));
                    assert(DART_IS_ERR(check(physical+1,1)));
                    assert(DART_IS_ERR(check(0,1)));
                    assert(searches==old_searches && translations==old_translations);
                    assert(dart_get_mapping(NULL,"fixture",physical,1)==DART_PTR_ERR); cases++;
                    for (unsigned bit=38;bit<64;bit++) {
                        assert(source_dart_translate(&dart,base|(1ULL<<bit))==NULL); cases++;
                    }
                }
            }
            /* Last page of the last supported TTBR: crossing it must fail. */
            setup(formats[f],formats[f]->ttbr_count-1,2047,2047,1);
            assert(check(physical,SZ_16K)==base);
            assert(DART_IS_ERR(check(physical,SZ_16K+1)));
            assert(source_dart_translate(&dart,(u64)formats[f]->ttbr_count<<36)==NULL); cases++;
            /* Valid TTBR transition for the existing four-root formats. */
            if (formats[f]->ttbr_count>1) {
                setup(formats[f],0,2047,2046,4);
                assert(check(physical,4*SZ_16K)==base);
                *entry(2)=0; assert(DART_IS_ERR(check(physical,4*SZ_16K)));
            }
        }
        negative("hole"); negative("remapped-middle"); negative("zero-length");
        negative("extent-overflow"); negative("iova-alias");
    }
    printf("PASS: %u retained-mapping cases; actual C DART/helper, owned tables, no hardware\n",cases);
}
