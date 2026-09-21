/* SPDX-License-Identifier: GPL-2.0+ */
/* Include the real driver under its generated Apple configuration. The only
 * reachable device operations address these process-owned arrays; no device
 * is opened. This tests command bookkeeping, not DMA, firmware, or storage. */
#ifndef UBOOT_NVME_SOURCE
#error "Define UBOOT_NVME_SOURCE as the absolute path to the pinned nvme_apple.c"
#endif
#if !defined(__aarch64__)
#error "Run inside the offline AArch64 Linux container"
#endif
#include UBOOT_NVME_SOURCE

extern void exit(int status) __attribute__((noreturn));

#define CHECK(condition) do { \
    if (!(condition)) { \
        printf("check failed: %s at line %d\n", #condition, __LINE__); \
        exit(1); \
    } \
} while (0)

static struct apple_nvme_priv fixture;
static struct nvme_queue queue;
static struct nvme_command command;
static u8 tcb_memory[ANS_NVMMU_TCB_SIZE] __attribute__((aligned(4096)));
static u32 registers[0x28200 / sizeof(u32)];
static u32 doorbell;
static bool expect_alignment_panic;

static void check_tcb(const struct ans_nvmmu_tcb *expected)
{
    unsigned start = queue.sq_tail * ANS_NVMMU_TCB_PITCH;
    for (unsigned i = 0; i < sizeof(tcb_memory); i++) {
        u8 value = i >= start && i < start + sizeof(*expected)
            ? ((const u8 *)expected)[i - start] : 0xa5;
        CHECK(tcb_memory[i] == value);
    }
}

/* BUG_ON reaches the real driver's panic path. Reject any descriptor/register
 * write before the expected alignment rejection, then exit with a distinct
 * code for the container runner. No trap, hang, or hardware reset is used. */
void panic(const char *format, ...)
{
    (void)format;
    CHECK(expect_alignment_panic);
    CHECK(doorbell == 0xa5a5a5a5U);
    for (unsigned i = 0; i < sizeof(tcb_memory); i++)
        CHECK(tcb_memory[i] == 0xa5);
    for (unsigned i = 0; i < ARRAY_SIZE(registers); i++)
        CHECK(registers[i] == 0xa5a5a5a5U);
    printf("admin_alignment_rejected_before_writes=true\n");
    exit(91);
}

static void reset_fixture(unsigned qid, unsigned page_size, unsigned tail)
{
    memset(&fixture, 0, sizeof(fixture));
    memset(&queue, 0, sizeof(queue));
    memset(&command, 0, sizeof(command));
    memset(tcb_memory, 0xa5, sizeof(tcb_memory));
    memset(registers, 0xa5, sizeof(registers));
    doorbell = 0xa5a5a5a5U;
    expect_alignment_panic = false;
    fixture.ndev.page_size = page_size;
    fixture.ndev.bar = (struct nvme_bar *)registers;
    fixture.tcbs[qid] = (struct ans_nvmmu_tcb *)tcb_memory;
    fixture.q_db[qid] = &doorbell;
    queue.dev = &fixture.ndev;
    queue.qid = qid;
    queue.q_depth = ANS_MAX_QUEUE_DEPTH;
    queue.sq_tail = tail;
}

static void exercise_command(void)
{
    unsigned tail = queue.sq_tail;
    struct ans_nvmmu_tcb expected;
    memset(&expected, 0, sizeof(expected));
    expected.flags = command.common.prp1 ? 3 : 0;
    expected.slot = tail;
    expected.prpl_len = command.rw.length;
    expected.prp1 = command.common.prp1;
    expected.prp2 = command.common.prp2;

    apple_nvme_submit_cmd(&queue, &command);
    CHECK(queue.sq_tail == tail);
    CHECK(doorbell == tail);
    check_tcb(&expected);
    for (unsigned i = 0; i < ARRAY_SIZE(registers); i++)
        CHECK(registers[i] == 0xa5a5a5a5U);

    apple_nvme_complete_cmd(&queue, &command);
    CHECK(queue.sq_tail == (tail + 1) % ANS_MAX_QUEUE_DEPTH);
    CHECK(doorbell == tail);
    memset(&expected, 0, sizeof(expected));
    queue.sq_tail = tail; /* Inspect the completed descriptor, not the next one. */
    check_tcb(&expected);
    for (unsigned i = 0; i < ARRAY_SIZE(registers); i++)
        CHECK(registers[i] == (i == ANS_NVMMU_TCB_INVAL / 4 ? tail : 0xa5a5a5a5U));
}

int main(int argc, char **argv)
{
    unsigned cases = 0;
    const unsigned pages[] = {4096, 16384};
    const unsigned tails[] = {0, 1, ANS_MAX_QUEUE_DEPTH - 1};
    const u8 opcodes[] = {0, 1, 2, 6, 9, 0xff};
    const u16 lengths[] = {0, 1, 0xffff};

    /* Six separate-process negative cases: page size 4/16 KiB, unaligned
     * PRP1, PRP2, or both. A normal return is always a test failure. */
    if (argc == 3) {
        CHECK(!strcmp(argv[1], "4096") || !strcmp(argv[1], "16384"));
        CHECK(!strcmp(argv[2], "1") || !strcmp(argv[2], "2") || !strcmp(argv[2], "3"));
        unsigned page_size = !strcmp(argv[1], "4096") ? 4096 : 16384;
        reset_fixture(NVME_ADMIN_Q, page_size, 0);
        command.common.prp1 = page_size + (argv[2][0] != '2');
        command.common.prp2 = 2 * page_size + (argv[2][0] != '1');
        expect_alignment_panic = true;
        apple_nvme_submit_cmd(&queue, &command);
        CHECK(false);
    }
    CHECK(argc == 1);

    for (unsigned qid = NVME_ADMIN_Q; qid <= NVME_IO_Q; qid++)
        for (unsigned p = 0; p < ARRAY_SIZE(pages); p++)
            for (unsigned t = 0; t < ARRAY_SIZE(tails); t++)
                for (unsigned op = 0; op < ARRAY_SIZE(opcodes); op++)
                    for (unsigned data = 0; data < (qid == NVME_IO_Q ? 5U : 4U); data++)
                        for (unsigned len = 0; len < ARRAY_SIZE(lengths); len++) {
                            reset_fixture(qid, pages[p], tails[t]);
                            command.common.opcode = opcodes[op];
                            command.rw.length = lengths[len];
                            command.common.prp1 = data >= 2 ? pages[p] : 0;
                            command.common.prp2 = data == 1 || data >= 3 ? 2 * pages[p] : 0;
                            if (data == 4) { /* I/O PRPs do not have the admin restriction. */
                                command.common.prp1++;
                                command.common.prp2 += 7;
                            }
                            exercise_command();
                            cases++;
                        }
    printf("apple_nvme_command_cases=%u passed; hardware_acceptance=false\n", cases);
    return 0;
}
