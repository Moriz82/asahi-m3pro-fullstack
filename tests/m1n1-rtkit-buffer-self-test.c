/* SPDX-License-Identifier: MIT */
/* Actual rtkit.c; mocked allocator/DART/SART/mailbox, no device access. */
#include <assert.h>
#include <malloc.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "rtkit.h"
#include "utils.h"

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static void *test_memalign(size_t alignment, size_t size);
static void test_free(void *pointer);
#define memalign test_memalign
#define free test_free
#include M1N1_RTKIT_SOURCE
#undef memalign
#undef free
#undef printf

static bool map_succeeded(rtkit_dev_t *rtk, void *phys, size_t size, u64 *dva)
{
#ifdef DART_LIFECYCLE
    return rtkit_map(rtk, phys, size, dva) == 0;
#else
    return rtkit_map(rtk, phys, size, dva);
#endif
}

static unsigned cases, allocs, frees, maps, unmaps, releases, sends, translations;
static unsigned adds, removes, break_page;
static bool fail_alloc, fail_map, fail_send, fail_sart, fail_iova, discontiguous;
static u64 next_iova, mapped_iova, unmapped_iova, released_iova, translated_base;
static size_t allocated_size, mapped_size, released_size;
static unsigned char *allocation;
static unsigned char physical[2 * 1024 * 1024] __attribute__((aligned(16384)));
static unsigned char *translation_memory = physical;
static struct asc_message sent;

int debug_printf(const char *fmt, ...) { (void)fmt; return 0; }
bool is_heap(void *addr) { return addr == allocation; }

static void *test_memalign(size_t alignment, size_t size)
{
    assert(alignment == SZ_16K && !allocation);
    allocs++;
    allocated_size = size;
    if (fail_alloc)
        return NULL;
    assert(!posix_memalign((void **)&allocation, alignment, ALIGN_UP(size, alignment)));
    return allocation;
}

static void test_free(void *pointer)
{
    assert(pointer && pointer == allocation);
    frees++;
    free(pointer);
    allocation = NULL;
}

u64 iova_alloc(iova_domain_t *domain, size_t size)
{
    assert(domain && size && !(size & (SZ_16K - 1)));
    return fail_iova ? 0 : next_iova;
}

void iova_free(iova_domain_t *domain, u64 iova, size_t size)
{
    assert(domain);
    releases++;
    released_iova = iova;
    released_size = size;
}

int dart_map(dart_dev_t *dart, uintptr_t iova, void *buffer, size_t size)
{
    assert(dart && buffer);
    maps++;
    mapped_iova = iova;
    mapped_size = size;
    return fail_map ? -1 : 0;
}

#ifdef DART_LIFECYCLE
bool dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
#else
void dart_unmap(dart_dev_t *dart, uintptr_t iova, size_t size)
#endif
{
    assert(dart && size);
    unmaps++;
    unmapped_iova = iova;
#ifdef DART_LIFECYCLE
    return true;
#endif
}

void *dart_translate(dart_dev_t *dart, uintptr_t iova)
{
    assert(dart);
    translations++;
    if (iova < translated_base || iova - translated_base >= sizeof(physical))
        return NULL;
    size_t off = iova - translated_base;
    if (off / SZ_16K == break_page)
        return discontiguous ? translation_memory + off + SZ_16K : NULL;
    return translation_memory + off;
}

bool asc_send(asc_dev_t *asc, const struct asc_message *msg)
{
    assert(asc);
    sends++;
    sent = *msg;
    return !fail_send;
}

bool sart_add_allowed_region(sart_dev_t *sart, void *buffer, size_t size)
{
    assert(sart && buffer && size);
    adds++;
    return !fail_sart;
}

bool sart_remove_allowed_region(sart_dev_t *sart, void *buffer, size_t size)
{
    assert(sart && buffer && size);
    removes++;
    return !fail_sart;
}

static rtkit_dev_t fresh(void)
{
    assert(!allocation);
    allocs = frees = maps = unmaps = releases = sends = translations = adds = removes = 0;
    allocated_size = mapped_size = released_size = 0;
    mapped_iova = unmapped_iova = released_iova = 0;
    fail_alloc = fail_map = fail_send = fail_sart = fail_iova = discontiguous = false;
    translation_memory = physical;
    break_page = (unsigned)-1;
    next_iova = translated_base = (1ULL << 40) + 0x10000000;
    return (rtkit_dev_t){.name = "test", .asc = (void *)1, .dart = (void *)2,
                         .dart_iovad = (void *)3};
}

static struct rtkit_message request(u64 addr, unsigned pages)
{
    assert(addr <= MSG_BUFFER_REQUEST_IOVA && pages <= 255);
    return (struct rtkit_message){.ep = RTKIT_EP_SYSLOG,
        .msg = FIELD_PREP(MGMT_TYPE, MSG_BUFFER_REQUEST) |
               FIELD_PREP(MSG_BUFFER_REQUEST_SIZE, pages) | addr};
}

static void high_unmap(void)
{
    rtkit_dev_t rtk = fresh();
    u64 dva = 0;
    assert(map_succeeded(&rtk, physical, SZ_16K, &dva));
    assert(dva == next_iova && mapped_iova == next_iova);
    assert(rtkit_unmap(&rtk, dva, SZ_16K));
    assert(unmapped_iova == next_iova && released_iova == next_iova);
    cases++;
}

static void allocation_size(void)
{
    rtkit_dev_t rtk = fresh();
    struct rtkit_buffer buffer = {0};
    assert(rtkit_alloc_buffer(&rtk, &buffer, 4097));
    assert(allocated_size == SZ_16K && buffer.sz == SZ_16K && mapped_size == SZ_16K);
    (void)rtkit_free_buffer(&rtk, &buffer);
    cases++;
}

static void free_result(void)
{
    rtkit_dev_t rtk = fresh();
    struct rtkit_buffer buffer = {0};
    assert(rtkit_alloc_buffer(&rtk, &buffer, SZ_16K));
    assert(rtkit_free_buffer(&rtk, &buffer));
    assert(!buffer.bfr && !buffer.sz && !buffer.dva);
    assert(rtkit_free_buffer(&rtk, &buffer));
    assert(frees == 1 && releases == 1 && unmaps == 1);
    cases++;
}

static void high_borrowed(void)
{
    rtkit_dev_t rtk = fresh();
    struct rtkit_buffer buffer = {0};
    struct rtkit_message msg = request(next_iova, 9);
    assert(rtkit_handle_buffer_request(&rtk, &msg, &buffer));
    assert(buffer.bfr == physical && buffer.dva == next_iova && buffer.sz == 9 * 4096);
    assert(!sends && !allocs);
    assert(rtkit_free_buffer(&rtk, &buffer));
    assert(!frees && !releases && !unmaps);
    cases++;
}

#ifndef BASELINE
static void all_cases(void)
{
    high_unmap(); allocation_size(); free_result(); high_borrowed();
    for (unsigned bit = 32; bit < 47; bit++) {
        rtkit_dev_t rtk = fresh();
        next_iova = (1ULL << bit) + SZ_16K;
        rtk.dva_base = 1ULL << 63;
        u64 dva = 0;
        assert(map_succeeded(&rtk, physical, SZ_16K, &dva));
        assert(dva == (next_iova | rtk.dva_base));
        assert(rtkit_unmap(&rtk, dva, SZ_16K));
        assert(unmapped_iova == next_iova && released_iova == next_iova);
        cases++;
    }
    for (unsigned pages = 1; pages <= 255; pages++) {
        rtkit_dev_t rtk = fresh();
        struct rtkit_buffer buffer = {0};
        struct rtkit_message msg = request(0, pages);
        assert(rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(FIELD_GET(MSG_BUFFER_REQUEST_IOVA, sent.msg0) == next_iova);
        assert(FIELD_GET(MSG_BUFFER_REQUEST_SIZE, sent.msg0) == pages);
        assert(FIELD_GET(MGMT_TYPE, sent.msg0) == MSG_BUFFER_REQUEST && sent.msg1 == msg.ep);
        assert(buffer.owned && allocated_size == ALIGN_UP(pages * 4096UL, SZ_16K));
        memset(buffer.bfr, 0x5a, buffer.sz);
        assert(rtkit_free_buffer(&rtk, &buffer));
        assert(!buffer.owned && frees == 1 && unmaps == 1 && releases == 1);
        assert(released_size == allocated_size && released_iova == next_iova);
        cases++;
    }
    for (unsigned page = 0; page < 4; page++) {
        rtkit_dev_t rtk = fresh();
        struct rtkit_buffer buffer = {0};
        struct rtkit_message msg = request(next_iova + 4096, 13);
        break_page = page;
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(!buffer.bfr && !buffer.sz && !buffer.dva && !buffer.owned);
        assert(!allocs && !maps && !unmaps && !frees && !sends);
        cases++;
    }
    for (unsigned page = 1; page < 4; page++) {
        rtkit_dev_t rtk = fresh();
        struct rtkit_buffer buffer = {0};
        struct rtkit_message msg = request(next_iova, 16);
        break_page = page;
        discontiguous = true;
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(!buffer.bfr && !buffer.owned && !sends && !unmaps);
        cases++;
    }
    {
        rtkit_dev_t rtk = fresh();
        translation_memory = test_memalign(SZ_16K, SZ_16K);
        struct rtkit_buffer buffer = {0};
        struct rtkit_message msg = request(next_iova, 4);
        assert(rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(buffer.bfr == allocation && !buffer.owned);
        assert(rtkit_free_buffer(&rtk, &buffer));
        assert(allocation && !frees && !unmaps && !releases && !buffer.bfr);
        test_free(allocation);
        cases++;
    }
    for (unsigned which = 0; which < 6; which++) {
        rtkit_dev_t rtk = fresh();
        struct rtkit_buffer buffer = {0};
        struct rtkit_message msg = request(0, 5);
        fail_alloc = which == 0; fail_iova = which == 1;
        fail_map = which == 2; fail_send = which == 3;
        if (which == 4) next_iova = 1ULL << 42;
        if (which == 5) rtk.dva_base = 1ULL << 43;
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(!buffer.bfr && !buffer.owned && !allocation);
        assert(sends == (which == 3));
        if (which >= 3) assert(unmaps == 1 && releases == 1 && frees == 1);
        if (which == 2) assert(!unmaps && releases == 1 && frees == 1);
        cases++;
    }
    for (unsigned which = 0; which < 5; which++) {
        rtkit_dev_t rtk = fresh();
        u64 dva = 0x1234;
        rtk.dva_base = 1ULL << 36;
        size_t size = SZ_16K;
        if (which == 0) next_iova = rtk.dva_base + SZ_16K;
        if (which == 1) { next_iova = rtk.dva_base - SZ_16K; size *= 2; }
        if (which == 2) { next_iova = SZ_16K; size = 1ULL << 38; }
        if (which == 3) { next_iova = (u64)-SZ_16K; size *= 2; }
        if (which == 4) next_iova++;
        assert(!map_succeeded(&rtk, physical, size, &dva));
        assert(dva == 0x1234 && !maps && !unmaps && releases == 1);
        cases++;
    }
    for (unsigned which = 0; which < 3; which++) {
        rtkit_dev_t rtk = fresh();
        struct rtkit_buffer buffer = {0};
        size_t size = which == 0 ? 0 : (size_t)-1 - which;
        assert(!rtkit_alloc_buffer(&rtk, &buffer, size));
        assert(!allocs && !maps && !buffer.bfr);
        cases++;
    }
    {
        rtkit_dev_t rtk = fresh();
        struct rtkit_buffer buffer = {0};
        assert(rtkit_alloc_buffer(&rtk, &buffer, SZ_16K));
        void *original = buffer.bfr;
        assert(!rtkit_alloc_buffer(&rtk, &buffer, SZ_16K));
        struct rtkit_message msg = request(next_iova, 4);
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(buffer.bfr == original && buffer.owned && allocs == 1);
        assert(rtkit_free_buffer(&rtk, &buffer));
        cases++;
    }
    {
        rtkit_dev_t rtk = fresh();
        rtk.dva_base = 1ULL << 41;
        next_iova = translated_base = SZ_16K;
        struct rtkit_buffer buffer = {0};
        struct rtkit_message msg = request(next_iova | rtk.dva_base, 8);
        assert(rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(buffer.dva == (next_iova | rtk.dva_base) && buffer.bfr == physical);
        assert(!buffer.owned && translations == 2 && !sends);
        assert(rtkit_free_buffer(&rtk, &buffer));
        assert(!buffer.bfr && !unmaps && !frees);
        msg = request(0, 4);
        assert(rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(FIELD_GET(MSG_BUFFER_REQUEST_IOVA, sent.msg0) == (next_iova | rtk.dva_base));
        assert(rtkit_free_buffer(&rtk, &buffer));
        assert(unmapped_iova == next_iova);
        cases++;
    }
    {
        rtkit_dev_t rtk = fresh();
        rtk.dart = NULL; rtk.dart_iovad = NULL; rtk.sart = (void *)4;
        struct rtkit_buffer buffer = {0};
        assert(rtkit_alloc_buffer(&rtk, &buffer, 1));
        assert(adds == 1 && buffer.dva == (u64)buffer.bfr);
        fail_sart = true;
        assert(!rtkit_free_buffer(&rtk, &buffer));
        assert(buffer.owned && buffer.bfr == allocation && !frees);
        fail_sart = false;
        assert(rtkit_free_buffer(&rtk, &buffer));
        assert(frees == 1 && removes == 2 && !buffer.owned);
        struct rtkit_message msg = request(next_iova, 4);
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(!translations && !buffer.bfr);
        rtk.sart = NULL; rtk.sram = true;
        assert(rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(buffer.bfr == (void *)next_iova && !buffer.owned);
        assert(rtkit_free_buffer(&rtk, &buffer));
        msg = request(0, 4);
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        msg = request(MSG_BUFFER_REQUEST_IOVA - 4095, 2);
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        msg = request(next_iova, 0);
        assert(!rtkit_handle_buffer_request(&rtk, &msg, &buffer));
        assert(!sends);
        cases++;
    }
}
#endif

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "high-unmap")) high_unmap();
    else if (!strcmp(argv[1], "allocation-size")) allocation_size();
    else if (!strcmp(argv[1], "free-result")) free_result();
    else if (!strcmp(argv[1], "high-borrowed")) high_borrowed();
#ifndef BASELINE
    else if (!strcmp(argv[1], "all")) all_cases();
#endif
    else assert(!"unknown mode");
    assert(!allocation);
    printf("PASS: %u actual RTKit buffer cases\n", cases);
}
