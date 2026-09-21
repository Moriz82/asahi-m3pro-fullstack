/* SPDX-License-Identifier: MIT */
/* Actual iova.c + rtkit.c. Only host memory, DART and mailbox are fakes. */
#include <assert.h>
#include <malloc.h>
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "utils.h"

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static unsigned calls, live, fail_at, cases, table_frees;
static u64 last_table;
static bool catch_panic;
static jmp_buf panic_jump;
static void *test_calloc(size_t n, size_t size);
static void test_free(void *p);
static _Noreturn void test_panic(void);
#undef panic
#define panic(...) test_panic()
#define calloc test_calloc
#define free test_free
#include M1N1_IOVA_SOURCE
#undef calloc
#undef free
#include M1N1_RTKIT_SOURCE
#undef printf

int debug_printf(const char *fmt, ...) { (void)fmt; return 0; }

static void *test_calloc(size_t n, size_t size)
{
    calls++;
    if (calls == fail_at) return NULL;
    void *p = calloc(n, size);
    assert(p);
    live++;
    return p;
}

static void test_free(void *p)
{
    assert(p && live);
    live--;
    free(p);
}

static _Noreturn void test_panic(void)
{
    if (catch_panic) longjmp(panic_jump, 1);
    assert(!"unexpected allocator panic");
    abort();
}

#ifdef DART_LIFECYCLE
static bool fail_table_release;
bool dart_free_l2(dart_dev_t *dart, uintptr_t addr)
#else
void dart_free_l2(dart_dev_t *dart, uintptr_t addr)
#endif
{
    assert(dart && (!table_frees || addr > last_table));
    last_table = addr;
    table_frees++;
    assert(table_frees < 40);
#ifdef DART_LIFECYCLE
    return !fail_table_release;
#endif
}

static unsigned maps, unmaps, sends;
static bool map_failure, send_failure;
static u64 mapped, unmapped;
static size_t mapped_size;
static struct asc_message sent;

int dart_map(dart_dev_t *dart, uintptr_t iova, void *buffer, size_t size)
{
    assert(dart && buffer && size && !(size & (SZ_16K - 1)));
    maps++; mapped = iova; mapped_size = size;
    return map_failure ? -1 : 0;
}
#ifdef DART_LIFECYCLE
bool dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
#else
void dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
#endif
{
    assert(dart && size); unmaps++; unmapped = iova;
#ifdef DART_LIFECYCLE
    return true;
#endif
}
void *dart_translate(dart_dev_t *dart, uintptr_t iova)
{
    (void)dart; (void)iova; assert(!"not a borrowed-buffer test"); return NULL;
}
bool sart_add_allowed_region(sart_dev_t *sart, void *b, size_t n)
{ (void)sart; (void)b; (void)n; assert(!"not SART"); return false; }
bool sart_remove_allowed_region(sart_dev_t *sart, void *b, size_t n)
{ (void)sart; (void)b; (void)n; assert(!"not SART"); return false; }
bool asc_send(asc_dev_t *asc, const struct asc_message *msg)
{ assert(asc); sends++; sent = *msg; return !send_failure; }

static iova_domain_t *domain(u64 base, unsigned pages)
{
    fail_at = 0;
    iova_domain_t *d = iovad_init(base, base + pages * (u64)SZ_16K);
    assert(d);
    return d;
}

/* Consistent owned free-list fixture isolates operations from old init bugs. */
static iova_domain_t *operation_fixture(void)
{
    iova_domain_t *d = test_calloc(1, sizeof(*d));
    d->base = SZ_32M; d->limit = d->base + 8 * SZ_16K;
    d->free_list = test_calloc(1, sizeof(*d->free_list));
    *d->free_list = (struct iova_block){.iova = d->base, .sz = 8 * SZ_16K};
    return d;
}

static void high_bounds(void)
{
    iova_domain_t *d = domain((1ULL << 40) + 0x10000000, 8);
    assert(d->free_list->iova == d->base && d->free_list->sz == 8 * SZ_16K);
    assert(iova_alloc(d, 8 * SZ_16K) == d->base);
    assert(!iova_alloc(d, SZ_16K));
    iovad_shutdown(d, NULL); cases++;
}

static void exact_reserve(void)
{
    iova_domain_t *d = operation_fixture();
    assert(iova_reserve(d, d->base, 8 * SZ_16K));
    assert(!d->free_list);
    iovad_shutdown(d, NULL); cases++;
}

static void tail_free(void)
{
    iova_domain_t *d = operation_fixture();
    u64 a = iova_alloc(d, 4 * SZ_16K), b = iova_alloc(d, 4 * SZ_16K);
    assert(a && b && !d->free_list);
    iova_free(d, a, 4 * SZ_16K);
    iova_free(d, b, 4 * SZ_16K);
    assert(d->free_list && d->free_list->sz == 8 * SZ_16K && !d->free_list->next);
    iovad_shutdown(d, NULL); cases++;
}

static void zero_base(void)
{
    iova_domain_t *d = domain(0, 8);
    assert(iova_alloc(d, SZ_16K) == SZ_16K);
    iovad_shutdown(d, NULL); cases++;
}

static void unaligned_reserve(void)
{
    iova_domain_t *d = operation_fixture();
    assert(iova_reserve(d, d->base + SZ_16K - 1, 2));
    assert(d->free_list->iova == d->base + 2 * SZ_16K);
    iovad_shutdown(d, NULL); cases++;
}

static void shutdown_wrap(void)
{
    iova_domain_t *d = domain((u64)-SZ_32M, 64);
    table_frees = 0;
    iovad_shutdown(d, (void *)1);
    assert(table_frees == 1 && last_table == (u64)-SZ_32M && !live); cases++;
}

static struct { iova_domain_t *iovad_dcp; } display_context, *dcp = &display_context;
static unsigned physical_allocs, display_maps;
static u64 display_iova;
static unsigned char framebuffer[8 * SZ_16K];

u64 top_of_memory_alloc(size_t size)
{
    assert(size <= sizeof(framebuffer)); physical_allocs++;
    return (u64)framebuffer;
}

static u64 display_map_fb(u64 iova, u64 phys, u64 size)
{
    assert(phys == (u64)framebuffer && size); display_maps++;
    /* A zero input is the real helper's search-anywhere sentinel. */
    return iova ? iova : SZ_16K;
}

static int display_allocation(size_t fb_size, size_t size)
{
    u64 fb_pa = 0, tmp_dva = 0;
#define printf debug_printf
#include "display-allocation.inc"
#undef printf
    }
    display_iova = tmp_dva;
    return 0;
}

static void display_exhaustion(void)
{
    iova_domain_t *d = operation_fixture();
    assert(iova_alloc(d, 8 * SZ_16K) == d->base && !d->free_list);
    dcp->iovad_dcp = d; physical_allocs = display_maps = 0;
    assert(display_allocation(0, SZ_16K) == -1);
    assert(!physical_allocs && !display_maps && !d->free_list);
    iovad_shutdown(d, NULL); cases++;
}

#ifndef BASELINE
static void model_check(iova_domain_t *d, const bool *used, unsigned pages)
{
    bool actual[64] = {0};
    assert(pages <= 64);
    u64 end = d->base;
    for (struct iova_block *b = d->free_list; b; b = b->next) {
        assert(b->sz && !(b->sz & (SZ_16K - 1)) && !(b->iova & (SZ_16K - 1)));
        assert(b->iova >= end && b->iova >= d->base && b->iova < d->limit);
        assert(b->sz <= d->limit - b->iova && b->iova);
        end = b->iova + b->sz;
        if (b->next) assert(end < b->next->iova);
        for (unsigned n = 0; n < b->sz / SZ_16K; n++) {
            unsigned i = (b->iova - d->base) / SZ_16K + n;
            assert(i < pages && !actual[i]); actual[i] = true;
        }
    }
    for (unsigned i = 0; i < pages; i++) assert(actual[i] == !used[i]);
}

static u32 random_state = 0x5eed1234;
static unsigned random_number(void)
{
    random_state ^= random_state << 13;
    random_state ^= random_state >> 17;
    random_state ^= random_state << 5;
    return random_state;
}

static void model_sequences(void)
{
    const u64 bases[] = {0, SZ_32M, 1ULL << 36, (1ULL << 40) + 0x10000000,
                         (1ULL << 47) - SZ_32M, (u64)-SZ_32M};
    for (unsigned profile = 0; profile < ARRAY_SIZE(bases); profile++) {
        iova_domain_t *d = domain(bases[profile], 64);
        bool used[64] = {0};
        if (!d->base) used[0] = true;
        model_check(d, used, 64);
        for (unsigned step = 0; step < 2000; step++) {
            unsigned op = random_number() % 3, pos = random_number() % 64;
            unsigned count = random_number() % 8 + 1;
            if (op == 0) {
                unsigned expected = 64;
                for (unsigned i = 0; i + count <= 64; i++) {
                    bool available = true;
                    for (unsigned j = i; j < i + count; j++) available &= !used[j];
                    if (available) { expected = i; break; }
                }
                size_t bytes = count * SZ_16K - random_number() % SZ_16K;
                u64 got = iova_alloc(d, bytes);
                assert(got == (expected == 64 ? 0 : d->base + expected * SZ_16K));
                if (got) for (unsigned j = expected; j < expected + count; j++) used[j] = true;
            } else if (op == 1) {
                if (count > 64 - pos) count = 64 - pos;
                bool expected = true;
                for (unsigned j = pos; j < pos + count; j++)
                    if (used[j] && (d->base || j)) expected = false;
                assert(iova_reserve(d, d->base + pos * SZ_16K, count * SZ_16K) == expected);
                if (expected) for (unsigned j = pos; j < pos + count; j++) used[j] = true;
            } else if (used[pos] && (d->base || pos)) {
                iova_free(d, d->base + pos * SZ_16K, SZ_16K);
                used[pos] = false;
            }
            model_check(d, used, 64); cases++;
        }
        iovad_shutdown(d, NULL); assert(!live);
    }
}

static void invalid_and_failure_cases(void)
{
    const u64 invalid[][2] = {{SZ_32M+1,2*SZ_32M}, {SZ_32M,SZ_32M},
        {SZ_32M,SZ_32M-1}, {0,0}, {0,SZ_16K}, {SZ_32M,SZ_32M+1},
        {(u64)-SZ_32M,(u64)-1}};
    for (unsigned i = 0; i < ARRAY_SIZE(invalid); i++) {
        unsigned before = calls;
        assert(!iovad_init(invalid[i][0], invalid[i][1]));
        assert(calls == before && !live); cases++;
    }
    for (unsigned fail = 1; fail <= 2; fail++) {
        fail_at = calls + fail;
        assert(!iovad_init(SZ_32M, 2 * SZ_32M));
        assert(!live); cases++;
    }
    fail_at = 0;
    iova_domain_t *d = domain(SZ_32M, 8);
    struct iova_block original = *d->free_list;
    fail_at = calls + 1;
    assert(!iova_reserve(d, d->base + SZ_16K, SZ_16K));
    assert(!memcmp(&original, d->free_list, sizeof(original)));
    fail_at = 0;
    assert(!iova_reserve(d, d->base - 1, 2));
    assert(!iova_reserve(d, d->limit - 1, 2));
    assert(!iova_reserve(d, (u64)-1, 2));
    assert(iova_reserve(d, d->base, 0));
    assert(!iova_alloc(d, 0) && !iova_alloc(d, (size_t)-1));
    assert(!iova_alloc(d, 9 * SZ_16K));
    iova_free(d, d->base, 0);
    assert(!memcmp(&original, d->free_list, sizeof(original))); cases++;
    const u64 bad[][2] = {{0,SZ_16K},{SZ_32M-1,1},{SZ_32M+1,1},
        {SZ_32M,(u64)-1},{SZ_32M,9*SZ_16K},{SZ_32M,SZ_16K}};
    for (volatile unsigned i = 0; i < ARRAY_SIZE(bad); i++) {
        catch_panic = true;
        if (!setjmp(panic_jump)) {
            iova_free(d, bad[i][0], bad[i][1]);
            assert(!"invalid free was accepted");
        }
        catch_panic = false;
        assert(!memcmp(&original, d->free_list, sizeof(original))); cases++;
    }
    u64 all = iova_alloc(d, 8 * SZ_16K); assert(all && !d->free_list);
    fail_at = calls + 1; catch_panic = true;
    if (!setjmp(panic_jump)) {
        iova_free(d, all, 8 * SZ_16K); assert(!"out-of-memory free accepted");
    }
    catch_panic = false; fail_at = 0;
    assert(!d->free_list);
    iova_free(d, all, 8 * SZ_16K);
    iovad_shutdown(d, NULL); assert(!live); cases++;
}

static void rtkit_integration(void)
{
    const u64 base = (1ULL << 40) + 0x10000000;
    iova_domain_t *d = domain(base, 64);
    rtkit_dev_t rtk = {.name="test",.dart=(void *)1,.dart_iovad=d,.asc=(void *)2};
    for (unsigned pages = 1; pages <= 255; pages++) {
        struct rtkit_buffer b = {0};
        struct rtkit_message msg = {.ep=RTKIT_EP_SYSLOG,
            .msg=FIELD_PREP(MGMT_TYPE,MSG_BUFFER_REQUEST) |
                 FIELD_PREP(MSG_BUFFER_REQUEST_SIZE,pages)};
        unsigned old_sends = sends;
        assert(rtkit_handle_buffer_request(&rtk,&msg,&b));
        assert(b.owned && b.dva == base && mapped == base);
        assert(mapped_size == ALIGN_UP(pages*4096UL,SZ_16K));
        assert(sends == old_sends + 1 && FIELD_GET(MSG_BUFFER_REQUEST_IOVA,sent.msg0)==base);
        assert(rtkit_free_buffer(&rtk,&b) && unmapped==base);
        assert(d->free_list->iova==base && d->free_list->sz==64*SZ_16K && !d->free_list->next);
        cases++;
    }
    struct rtkit_buffer buffers[16] = {0};
    for (unsigned i = 0; i < 16; i++) {
        assert(rtkit_alloc_buffer(&rtk,&buffers[i],4*SZ_16K));
        assert(buffers[i].dva == base + i*4*SZ_16K);
    }
    struct rtkit_buffer no_space = {0};
    unsigned old_maps = maps;
    assert(!rtkit_alloc_buffer(&rtk,&no_space,1) && !no_space.bfr && maps==old_maps);
    /* Deliberately non-LIFO: all coalescing paths participate. */
    for (unsigned i = 0; i < 16; i++) assert(rtkit_free_buffer(&rtk,&buffers[(i*7)%16]));
    assert(d->free_list->sz==64*SZ_16K && !d->free_list->next); cases++;
    map_failure=true;
    assert(!rtkit_alloc_buffer(&rtk,&no_space,1));
    map_failure=false;
    assert(d->free_list->sz==64*SZ_16K && !no_space.bfr); cases++;
    struct rtkit_message msg={.ep=RTKIT_EP_SYSLOG,
        .msg=FIELD_PREP(MGMT_TYPE,MSG_BUFFER_REQUEST)|FIELD_PREP(MSG_BUFFER_REQUEST_SIZE,4)};
    send_failure=true;
    assert(!rtkit_handle_buffer_request(&rtk,&msg,&no_space));
    send_failure=false;
    assert(d->free_list->sz==64*SZ_16K && !no_space.bfr); cases++;
    rtk.dva_base = 1ULL<<41;
    assert(rtkit_alloc_buffer(&rtk,&no_space,SZ_16K));
    assert(no_space.dva==(base|rtk.dva_base));
    assert(rtkit_free_buffer(&rtk,&no_space) && unmapped==base); cases++;
    iovad_shutdown(d,NULL); assert(!live);
}

static void display_fragmentation(void)
{
    iova_domain_t *d = domain((1ULL<<40) + 0x10000000, 8);
    for (unsigned i = 0; i < 8; i += 2) assert(iova_reserve(d,d->base+i*SZ_16K,SZ_16K));
    dcp->iovad_dcp = d; physical_allocs = display_maps = 0;
    assert(display_allocation(0,2*SZ_16K)==-1);
    assert(!physical_allocs && !display_maps);
    assert(display_allocation(0,SZ_16K)==0);
    assert(physical_allocs==1 && display_maps==1 && display_iova==d->base+SZ_16K);
    iova_free(d,display_iova,SZ_16K);
    assert(display_allocation(SZ_16K,SZ_16K)==0);
    assert(physical_allocs==1 && display_maps==1);
    iovad_shutdown(d,NULL); assert(!live); cases++;
}
#endif

int main(int argc, char **argv)
{
    assert(argc==2);
    if (!strcmp(argv[1],"high-bounds")) high_bounds();
    else if (!strcmp(argv[1],"exact-reserve")) exact_reserve();
    else if (!strcmp(argv[1],"tail-free")) tail_free();
    else if (!strcmp(argv[1],"zero-base")) zero_base();
    else if (!strcmp(argv[1],"unaligned-reserve")) unaligned_reserve();
    else if (!strcmp(argv[1],"shutdown-wrap")) shutdown_wrap();
    else if (!strcmp(argv[1],"display-exhaustion")) display_exhaustion();
#ifndef BASELINE
    else if (!strcmp(argv[1],"all")) {
        high_bounds(); exact_reserve(); tail_free(); zero_base(); unaligned_reserve(); shutdown_wrap();
        display_exhaustion(); model_sequences(); invalid_and_failure_cases(); rtkit_integration();
        display_fragmentation();
#ifdef DART_LIFECYCLE
        iova_domain_t *d = domain(SZ_32M, 8);
        void *saved_list = d->free_list;
        unsigned saved_live = live;
        table_frees = 0; fail_table_release = true;
        assert(!iovad_shutdown(d, (void *)1));
        assert(live == saved_live && d->free_list == saved_list && table_frees == 1);
        fail_table_release = false; table_frees = 0;
        assert(iovad_shutdown(d, (void *)1) && !live); cases++;
#endif
    }
#endif
    else assert(!"unknown mode");
    assert(!live);
    printf("PASS: %u IOVA/model/RTKit cases; actual allocator and RTKit C, no hardware\n",cases);
}
