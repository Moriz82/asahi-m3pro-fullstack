/* SPDX-License-Identifier: MIT */
/* Complete afk.c with fake RTKit transport/memory, never device access. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "afk.h"
#include "utils.h"
#include M1N1_AFK_SOURCE
#undef printf

#if !defined(__aarch64__) || defined(NDEBUG)
#error "Run on AArch64 Linux with assertions enabled"
#endif

static unsigned checks, sends, allocs, frees;
static bool queued, fail_send, fail_alloc, fail_free;
static u64 alloc_dva;
static void *allocation;
static struct rtkit_message incoming, outgoing;
static afk_epic_t afk;
static afk_epic_ep_t epic;
static unsigned char memory[8192] __attribute__((aligned(4096)));

int debug_printf(const char *fmt, ...) { (void)fmt; return 0; }
bool rtkit_send(rtkit_dev_t *rtk, const struct rtkit_message *msg)
{
    assert(rtk == (void *)1);
    sends++;
    outgoing = *msg;
    return !fail_send;
}
int rtkit_recv(rtkit_dev_t *rtk, struct rtkit_message *msg)
{
    assert(rtk == (void *)1);
    if (!queued)
        return 0;
    *msg = incoming;
    queued = false;
    return 1;
}
bool rtkit_can_recv(rtkit_dev_t *rtk) { assert(rtk == (void *)1); return queued; }
bool rtkit_alloc_buffer(rtkit_dev_t *rtk, struct rtkit_buffer *buffer, size_t size)
{
    assert(rtk == (void *)1);
    allocs++;
    if (buffer->bfr || !size || fail_alloc)
        return false;
    assert(!allocation);
    size = ALIGN_UP(size, SZ_16K);
    assert(!posix_memalign(&allocation, SZ_16K, size));
    memset(allocation, 0, size);
    *buffer = (struct rtkit_buffer){.bfr = allocation, .dva = alloc_dva,
                                  .sz = size, .owned = true};
    return true;
}
bool rtkit_free_buffer(rtkit_dev_t *rtk, struct rtkit_buffer *buffer)
{
    assert(rtk == (void *)1);
    if (fail_free)
        return false;
    if (buffer->owned) {
        assert(buffer->bfr == allocation);
        free(allocation);
        allocation = NULL;
        frees++;
    }
    *buffer = (struct rtkit_buffer){0};
    return true;
}

static void reset(void)
{
    assert(!allocation);
    memset(memory, 0, sizeof(memory));
    afk = (afk_epic_t){.rtk = (void *)1};
    epic = (afk_epic_ep_t){.ep = 0x20, .afk = &afk,
        .buf = {.bfr = memory, .sz = sizeof(memory), .dva = 1ULL << 40}};
    afk.endpoint[0] = &epic;
#ifndef BASELINE
    epic.buf_size = sizeof(memory);
#endif
    sends = allocs = frees = 0;
    queued = fail_send = fail_alloc = fail_free = false;
    alloc_dva = 1ULL << 40;
}

static u32 *read_pointer(void *start, unsigned block) { return start + block; }
static u32 *write_pointer(void *start, unsigned block) { return start + 2 * block; }
static struct afk_qe *entry(void *start, unsigned block, unsigned offset)
{
    return start + 3 * block + offset;
}
static void layout(void *start, unsigned block, unsigned capacity, u32 rptr, u32 wptr)
{
    *(u32 *)start = capacity;
    *read_pointer(start, block) = rptr;
    *write_pointer(start, block) = wptr;
}
static void ring(struct afk_rb *rb, unsigned block, unsigned capacity, u32 rptr, u32 wptr)
{
    layout(memory, block, capacity, rptr, wptr);
    assert(afk_rb_init(&epic, rb, 0, 3 * block + capacity));
}
static int poll_message(u64 type, u64 fields)
{
    incoming = (struct rtkit_message){.ep = 0x20,
        .msg = FIELD_PREP(RBEP_TYPE, type) | fields};
    queued = true;
    return afk_epic_poll(&afk, epic.ep, false);
}
static void request_buffer(void)
{
    epic.buf = (struct rtkit_buffer){0};
#ifndef BASELINE
    epic.buf_size = 0;
#endif
}

static void bad_window(void)
{
    reset();
    epic.buf.sz = 1024;
#ifndef BASELINE
    epic.buf_size = 1024;
#endif
    layout(memory + 512, 64, 512, 0, 0);
    assert(!afk_rb_init(&epic, &epic.rx, 512, 704));
    checks++;
}
static void bad_address(void)
{
    reset(); request_buffer();
    alloc_dva = (1ULL << 48) | 0x10000;
    assert(poll_message(RBEP_GETBUF, FIELD_PREP(GETBUF_SIZE, 64) | 0x4567) < 0);
    assert(!sends && frees == 1 && !epic.buf.bfr && !epic.tag);
    checks++;
}
static void header_wrap(void)
{
    reset(); ring(&epic.rx, 64, 512, 448, 128);
    struct afk_qe *tail = entry(memory, 64, 448), *head = entry(memory, 64, 0), *qe;
    *tail = (struct afk_qe){.magic = QE_MAGIC, .size = 60};
    *head = *tail;
    memset(head->data, 0xa5, 60);
    assert(afk_epic_rx(&epic, &qe) == 1 && qe == head);
    assert(*read_pointer(memory, 64) == 448);
    afk_epic_rx_ack(&epic);
    assert(*read_pointer(memory, 64) == 128);
    checks++;
}
static void uncommitted(void)
{
    reset(); ring(&epic.rx, 64, 512, 0, 64);
    *entry(memory, 64, 0) = (struct afk_qe){.magic = QE_MAGIC, .size = 80};
    struct afk_qe *qe = NULL;
    assert(afk_epic_rx(&epic, &qe) < 0 && !qe);
    assert(*read_pointer(memory, 64) == 0);
    checks++;
}
static void bad_position(void)
{
    reset(); ring(&epic.tx, 64, 512, 0, 0);
    *read_pointer(memory, 64) = 1024;
    assert(afk_epic_tx(&epic, 1, TYPE_COMMAND, memory, 0) < 0);
    assert(!sends && !*write_pointer(memory, 64));
    checks++;
}
static void stable_ack(void)
{
    reset(); ring(&epic.rx, 64, 512, 0, 128);
    struct afk_qe *head = entry(memory, 64, 0), *qe;
    *head = (struct afk_qe){.magic = QE_MAGIC};
    assert(afk_epic_rx(&epic, &qe) == 1);
    head->size = 80;
    afk_epic_rx_ack(&epic);
    assert(*read_pointer(memory, 64) == 64);
    checks++;
}
static void duplicate(void)
{
    reset(); ring(&epic.rx, 64, 512, 0, 0);
    assert(!afk_rb_init(&epic, &epic.rx, 0, 704));
    checks++;
}
static void block128(void)
{
    reset(); ring(&epic.tx, 128, 1024, 0, 0);
    char payload[129] = {7};
    assert(afk_epic_tx(&epic, 7, TYPE_COMMAND, payload, sizeof(payload)) == 1);
    assert(*write_pointer(memory, 128) == 256);
    assert(entry(memory, 128, 0)->size == sizeof(payload));
    assert(!memcmp(entry(memory, 128, 0)->data, payload, sizeof(payload)));
    checks++;
}
static void send_failure(void)
{
    reset(); ring(&epic.tx, 64, 512, 0, 0);
    fail_send = true;
    assert(afk_epic_tx(&epic, 1, TYPE_COMMAND, memory, 0) < 0);
    assert(*write_pointer(memory, 64) == 64 && sends == 1);
    fail_send = false;
    assert(afk_epic_tx(&epic, 1, TYPE_COMMAND, memory, 0) < 0);
    assert(*write_pointer(memory, 64) == 64 && sends == 1);
    checks++;
}

#ifndef BASELINE
static void geometry_cases(void)
{
    const u64 bases[] = {1, 63, sizeof(memory), sizeof(memory) + 64, (u64)-64};
    for (unsigned i = 0; i < sizeof(bases) / sizeof(*bases); i++) {
        reset(); layout(memory, 64, 512, 0, 0);
        assert(!afk_rb_init(&epic, &epic.rx, bases[i], 704));
        assert(!epic.rx.ready && !epic.rx.buf);
        checks++;
    }
    const u64 sizes[] = {0, 64, 256, 319, 321, 703, sizeof(memory) + 64, (u64)-64};
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
        reset(); layout(memory, 64, 512, 0, 0);
        assert(!afk_rb_init(&epic, &epic.rx, 0, sizes[i]));
        assert(!epic.rx.ready && !epic.rx.buf);
        checks++;
    }
    const unsigned capacities[] = {0, 1, 127, 513, 512 + 192, (u32)-1};
    for (unsigned i = 0; i < sizeof(capacities) / sizeof(*capacities); i++) {
        reset(); layout(memory, 64, capacities[i], 0, 0);
        assert(!afk_rb_init(&epic, &epic.rx, 0, 704));
        assert(!epic.rx.ready && !epic.rx.buf);
        checks++;
    }
    reset();
    epic.buf.bfr = NULL;
    assert(!afk_rb_init(&epic, &epic.rx, 0, 704));
    reset();
    epic.buf_size = epic.buf.sz + 1;
    assert(!afk_rb_init(&epic, &epic.rx, 0, 704));
    reset();
    layout(memory, 192, 768, 0, 0); /* Non-power-of-two block rejected. */
    assert(!afk_rb_init(&epic, &epic.rx, 0, 3 * 192 + 768));
    reset();
    layout(memory, 64, 512, 1, 0);
    assert(!afk_rb_init(&epic, &epic.rx, 0, 704));
    *read_pointer(memory, 64) = 0;
    *write_pointer(memory, 64) = 512;
    assert(!afk_rb_init(&epic, &epic.rx, 0, 704));
    *write_pointer(memory, 64) = 0;
    assert(afk_rb_init(&epic, &epic.rx, 0, 704));
    struct afk_rb saved = epic.rx;
    assert(!afk_rb_init(&epic, &epic.tx, 0, 704));
    assert(!epic.tx.ready && !memcmp(&saved, &epic.rx, sizeof(saved)));
    layout(memory + 704, 128, 1024, 0, 0);
    assert(afk_rb_init(&epic, &epic.tx, 704, 1408));
    assert(!afk_rb_init(&epic, &epic.rx, 704, 1408));
    assert(!memcmp(&saved, &epic.rx, sizeof(saved)));
    checks += 9;
}

static void handshake_cases(void)
{
    const u64 addresses[] = {0x200000, 1ULL << 40, (1ULL << 48) - SZ_16K,
                            (1ULL << 48) - 64, 1ULL << 48, 1ULL << 63, (u64)-1};
    for (unsigned i = 0; i < sizeof(addresses) / sizeof(*addresses); i++) {
        reset(); request_buffer(); alloc_dva = addresses[i];
        bool fits = alloc_dva <= (1ULL << 48) - SZ_16K;
        int ret = poll_message(RBEP_GETBUF, FIELD_PREP(GETBUF_SIZE, 64) | 0x4567);
        assert((ret == 0) == fits);
        if (fits) {
            assert(sends == 1 && epic.buf_size == 4096 && epic.buf.sz == SZ_16K);
            assert(epic.tag == 0x4567 && FIELD_GET(GETBUF_ACK_DVA, outgoing.msg) == alloc_dva);
            struct rtkit_buffer saved = epic.buf;
            assert(poll_message(RBEP_GETBUF, FIELD_PREP(GETBUF_SIZE, 1) | 0xabcd) < 0);
            assert(epic.tag == 0x4567 && epic.buf_size == 4096 && sends == 1);
            assert(!memcmp(&saved, &epic.buf, sizeof(saved)));
            assert(rtkit_free_buffer(afk.rtk, &epic.buf));
        } else {
            assert(!sends && frees == 1 && !epic.buf.bfr && !epic.buf_size && !epic.tag);
        }
        checks++;
    }
    for (unsigned failure = 0; failure < 4; failure++) {
        reset(); request_buffer();
        fail_alloc = failure == 0;
        fail_send = failure >= 1;
        fail_free = failure == 3;
        if (failure == 2)
            alloc_dva = 1ULL << 48;
        assert(poll_message(RBEP_GETBUF, FIELD_PREP(GETBUF_SIZE, 1) | 0xbeef) < 0);
        assert(!epic.tag && !epic.buf_size);
        assert((epic.buf.bfr != NULL) == fail_free);
        if (fail_free) {
            assert(allocation && epic.buf.owned);
            fail_free = false;
            assert(rtkit_free_buffer(afk.rtk, &epic.buf));
        }
        checks++;
    }
    reset(); request_buffer();
    assert(poll_message(RBEP_GETBUF, 0) < 0 && !sends && !epic.buf.bfr);
    assert(poll_message(RBEP_START_ACK, 0) < 0 && !epic.started);
    assert(poll_message(RBEP_INIT_RX, FIELD_PREP(INITRB_SIZE, 11)) < 0);
    assert(poll_message(RBEP_RECV, 0) < 0);
    assert(afk_epic_work(&afk, epic.ep) == 0); /* Registered, still uninitialized. */
    assert(poll_message(RBEP_GETBUF, FIELD_PREP(GETBUF_SIZE, 1)) == 0);
    layout(epic.buf.bfr, 64, 512, 0, 0);
    assert(poll_message(RBEP_INIT_RX, FIELD_PREP(INITRB_SIZE, 11)) < 0);
    assert(!epic.rx.ready); /* 704 bytes cannot use the allocator's 16K slack. */
    assert(rtkit_free_buffer(afk.rtk, &epic.buf));
    checks += 6;

    reset(); request_buffer();
    assert(poll_message(RBEP_GETBUF, FIELD_PREP(GETBUF_SIZE, 64) | 0x1234) == 0);
    layout(epic.buf.bfr, 64, 512, 0, 0);
    layout(epic.buf.bfr + 704, 128, 1024, 0, 0);
    assert(poll_message(RBEP_INIT_RX, FIELD_PREP(INITRB_SIZE, 11) | 0x1235) < 0);
    assert(!epic.rx.ready);
    assert(poll_message(RBEP_INIT_RX, FIELD_PREP(INITRB_SIZE, 11) | 0x1234) == 0);
    assert(sends == 1 && !epic.start_requested);
    assert(poll_message(RBEP_INIT_TX, FIELD_PREP(INITRB_OFFSET, 11) |
                       FIELD_PREP(INITRB_SIZE, 22) | 0x1234) == 0);
    assert(sends == 2 && epic.start_requested && !epic.started);
    assert(FIELD_GET(RBEP_TYPE, outgoing.msg) == RBEP_START);
    assert(poll_message(RBEP_START_ACK, 0) == 0 && epic.started);
    assert(poll_message(RBEP_INIT_TX, FIELD_PREP(INITRB_OFFSET, 11) |
                       FIELD_PREP(INITRB_SIZE, 22) | 0x1234) < 0);
    assert(sends == 2);
    assert(rtkit_free_buffer(afk.rtk, &epic.buf));
    checks++;
}

static void transport_edges(void)
{
    reset();
    struct afk_qe *qe = NULL;
    assert(afk_epic_rx(&epic, &qe) < 0 && !qe);
    assert(afk_epic_tx(&epic, 0, 0, NULL, 0) < 0);
    afk_epic_rx_ack(&epic);
    assert(epic.rx.failed);
    reset(); ring(&epic.rx, 64, 512, 0, 0);
    assert(afk_epic_rx(&epic, &qe) < 0 && !qe && !epic.rx.failed);
    assert(afk_epic_rx(&epic, NULL) < 0);
    reset(); ring(&epic.tx, 64, 512, 0, 0);
    unsigned char saved[sizeof(memory)];
    memcpy(saved, memory, sizeof(saved));
    const size_t sizes[] = {1, 513, (u32)-1, (1ULL << 32), (size_t)-1};
    for (unsigned i = 0; i < sizeof(sizes) / sizeof(*sizes); i++) {
        assert(afk_epic_tx(&epic, 0, 0, NULL, sizes[i]) < 0);
        assert(!sends && !memcmp(saved, memory, sizeof(saved)));
        checks++;
    }
    assert(afk_epic_tx(&epic, 0, 0, NULL, 0) == 1);
    for (unsigned which = 0; which < 2; which++) {
        const u32 positions[] = {1, 63, 511, 512, (u32)-1};
        for (unsigned i = 0; i < sizeof(positions) / sizeof(*positions); i++) {
            reset(); ring(&epic.rx, 64, 512, 0, 64);
            *(which ? write_pointer(memory, 64) : read_pointer(memory, 64)) = positions[i];
            memcpy(saved, memory, sizeof(saved));
            assert(afk_epic_rx(&epic, &qe) < 0 && !qe && epic.rx.failed);
            assert(!memcmp(saved, memory, sizeof(saved)));
            assert(afk_epic_work(&afk, epic.ep) < 0);
            checks++;
        }
    }
    reset(); ring(&epic.rx, 64, 512, 0, 64);
    *entry(memory, 64, 0) = (struct afk_qe){.magic = QE_MAGIC};
    assert(afk_epic_rx(&epic, &qe) == 1);
    assert(afk_epic_rx(&epic, &qe) < 0 && !qe);
    *read_pointer(memory, 64) = 128;
    afk_epic_rx_ack(&epic);
    assert(epic.rx.failed && *read_pointer(memory, 64) == 128);
    checks += 7;
}

static void malformed_cases(void)
{
    for (unsigned mode = 0; mode < 8; mode++) {
        reset(); ring(&epic.rx, 64, 512, 448, 128);
        struct afk_qe *tail = entry(memory, 64, 448), *head = entry(memory, 64, 0), *qe;
        *tail = (struct afk_qe){.magic = QE_MAGIC, .size = 60, .channel = 7, .type = 3};
        *head = *tail;
        switch (mode) {
            case 0: tail->magic = 0; break;
            case 1: head->magic = 0; break;
            case 2: head->size--; break;
            case 3: head->channel++; break;
            case 4: head->type++; break;
            case 5: *write_pointer(memory, 64) = 64; break;
            case 6: tail->size = head->size = (u32)-1; break;
            case 7: tail->size = head->size = 512; break;
        }
        assert(afk_epic_rx(&epic, &qe) < 0 && !qe && epic.rx.failed);
        assert(*read_pointer(memory, 64) == 448 && !epic.rx.pending);
        checks++;
    }
    reset(); ring(&epic.rx, 64, 512, 0, 64);
    *entry(memory, 64, 0) = (struct afk_qe){.magic = QE_MAGIC};
    assert(poll_message(RBEP_RECV, 0) == EPIC_DATA_READY);
    assert(afk_epic_work(&afk, epic.ep) == EPIC_DATA_READY);
    assert(afk_epic_work(&afk, -1) == 0); /* Consume/drop other endpoint data. */
    assert(*read_pointer(memory, 64) == 64 && !epic.rx.pending);
    afk_epic_rx_ack(&epic); /* Duplicate ack must not consume another entry. */
    assert(epic.rx.failed && *read_pointer(memory, 64) == 64);
    checks += 3;
}

static void exhaustive_transport(void)
{
    const unsigned blocks[] = {64, 128, 64};
    const unsigned counts[] = {8, 8, 3};
    unsigned char payload[2048], saved[sizeof(memory)];
    for (unsigned i = 0; i < sizeof(payload); i++)
        payload[i] = (i * 37 + 17) & 255;
    for (unsigned profile = 0; profile < 3; profile++) {
        unsigned block = blocks[profile], count = counts[profile], capacity = block * count;
        for (unsigned r = 0; r < count; r++) {
            for (unsigned w = 0; w < count; w++) {
                for (unsigned size = 0; size <= capacity; size++) {
                    reset(); ring(&epic.tx, block, capacity, r * block, w * block);
                    memcpy(saved, memory, sizeof(saved));
                    /* Independent block-occupancy model includes discarded wrap padding. */
                    unsigned slots = (sizeof(struct afk_qe) + size + block - 1) / block;
                    unsigned occupied = (w + count - r) % count;
                    unsigned needed = slots + (w + slots > count ? count - w : 0);
                    bool fits = needed <= count - 1 - occupied;
                    int ret = afk_epic_tx(&epic, 7, TYPE_COMMAND, payload, size);
                    assert((ret == 1) == fits);
                    if (!fits) {
                        assert(!sends && !epic.tx.failed && !memcmp(saved, memory, sizeof(saved)));
                    } else {
                        unsigned start = w + slots > count ? 0 : w;
                        unsigned next = (start + slots) % count;
                        assert(sends == 1 && *write_pointer(memory, block) == next * block);
                        assert(outgoing.ep == epic.ep && FIELD_GET(RBEP_TYPE, outgoing.msg) == RBEP_SEND);
                        assert(FIELD_GET(SEND_WPTR, outgoing.msg) == next * block);
                        /* Fake peer drains prior entries, then receives this real C TX frame. */
                        *read_pointer(memory, block) = w * block;
                        afk_epic_ep_t peer = {.rx = epic.tx};
                        struct afk_qe *qe;
                        assert(afk_epic_rx(&peer, &qe) == 1);
                        assert(qe == entry(memory, block, start * block));
                        assert(qe->magic == QE_MAGIC && qe->size == size &&
                               qe->channel == 7 && qe->type == TYPE_COMMAND);
                        assert(!memcmp(qe->data, payload, size));
                        assert(*read_pointer(memory, block) == w * block);
                        afk_epic_rx_ack(&peer);
                        assert(*read_pointer(memory, block) == next * block && !peer.rx.failed);
                        assert(afk_epic_rx(&peer, &qe) < 0 && !qe && !peer.rx.failed);
                    }
                    checks++;
                }
            }
        }
    }
}

static void queued_stream(void)
{
    const unsigned blocks[] = {64, 128, 64}, counts[] = {16, 8, 3};
    for (unsigned profile = 0; profile < 3; profile++) {
        reset(); ring(&epic.tx, blocks[profile], blocks[profile] * counts[profile], 0, 0);
        afk_epic_ep_t peer = {.rx = epic.tx};
        struct { u32 sequence, size; } expected[16];
        unsigned head = 0, tail = 0, outstanding = 0;
        unsigned char payload[241];
        u32 random = 0x51afc123;
        for (unsigned iteration = 0; iteration < 10000; iteration++) {
            random = random * 1664525 + 1013904223;
            unsigned size = (random >> 16) % sizeof(payload);
            memset(payload, iteration & 255, size);
            bool sent = afk_epic_tx(&epic, iteration, TYPE_COMMAND, payload, size) == 1;
            if (sent) {
                assert(outstanding < counts[profile] - 1);
                expected[tail].sequence = iteration;
                expected[tail].size = size;
                tail = (tail + 1) % 16;
                outstanding++;
            }
            if (outstanding && (!sent || (random & 1))) {
                struct afk_qe *qe;
                assert(afk_epic_rx(&peer, &qe) == 1);
                assert(qe->channel == expected[head].sequence && qe->size == expected[head].size);
                memset(payload, expected[head].sequence & 255, qe->size);
                assert(!memcmp(qe->data, payload, qe->size));
                head = (head + 1) % 16;
                outstanding--;
                afk_epic_rx_ack(&peer);
            }
            assert(!epic.tx.failed && !peer.rx.failed && !peer.rx.pending);
            assert((outstanding == 0) ==
                   (*read_pointer(memory, blocks[profile]) == *write_pointer(memory, blocks[profile])));
            checks++;
        }
        while (outstanding--) {
            struct afk_qe *qe;
            assert(afk_epic_rx(&peer, &qe) == 1);
            assert(qe->channel == expected[head].sequence && qe->size == expected[head].size);
            head = (head + 1) % 16;
            afk_epic_rx_ack(&peer);
        }
        assert(*read_pointer(memory, blocks[profile]) == *write_pointer(memory, blocks[profile]));
    }
}

static void all_cases(void)
{
    bad_window(); bad_address(); header_wrap(); uncommitted(); bad_position(); stable_ack();
    duplicate(); block128(); send_failure();
    geometry_cases(); handshake_cases(); transport_edges(); malformed_cases();
    exhaustive_transport();
    queued_stream();
}
#endif

int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "window")) bad_window();
    else if (!strcmp(argv[1], "address")) bad_address();
    else if (!strcmp(argv[1], "wrap")) header_wrap();
    else if (!strcmp(argv[1], "uncommitted")) uncommitted();
    else if (!strcmp(argv[1], "position")) bad_position();
    else if (!strcmp(argv[1], "ack")) stable_ack();
    else if (!strcmp(argv[1], "duplicate")) duplicate();
    else if (!strcmp(argv[1], "block128")) block128();
    else if (!strcmp(argv[1], "send-failure")) send_failure();
#ifndef BASELINE
    else if (!strcmp(argv[1], "all")) all_cases();
#endif
    else assert(0);
    assert(!allocation);
    printf("PASS: %u AFK ring/handshake checks; actual afk.c; ASan/UBSan\n", checks);
}
