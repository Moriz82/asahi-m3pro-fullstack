/* SPDX-License-Identifier: MIT */
/* Actual private structs and client lifecycle functions, fake AFK boundary. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "afk.h"
#include "dcp.h"
#include "dcp_iboot.h"
#include "client-types.inc"
static unsigned live, creates, destroys, cases;
static bool fail_allocate, fail_start, fail_interface, fail_shutdown;
static void *allocation;
static dcp_dev_t owner;
static void *allocate(size_t count, size_t size)
{ assert(!live && count == 1 && size == sizeof(TYPE)); if (fail_allocate) return NULL;
  allocation = calloc(count, size); assert(allocation); live++; return allocation; }
static void release(void *pointer)
{ assert(pointer == allocation && live == 1); free(pointer); allocation = NULL; live--; }
static int diagnostic(const char *format, ...) { (void)format; return 0; }
afk_epic_ep_t *afk_epic_start_ep(afk_epic_t *afk, int endpoint,
                              const afk_epic_service_ops_t *ops, bool notify)
{ assert(afk == (void *)1 && endpoint == EP && ops && notify == (EP != 0x23));
  creates++; return fail_start ? NULL : (void *)2; }
int afk_epic_start_interface(afk_epic_ep_t *epic, void *intf, int count, size_t tx, size_t rx)
{ assert(epic == (void *)2 && intf == allocation && count == COUNT && tx == 0x4000 && rx == 0x4000);
  TYPE *p = intf; COMPLETE(p); return fail_interface ? -1 : 0; }
int afk_epic_shutdown_ep(afk_epic_ep_t *epic)
{ assert(epic == (void *)2); destroys++; return fail_shutdown ? -1 : 0; }
#define calloc allocate
#define free release
#define printf diagnostic
#include "client-functions.inc"
#undef calloc
#undef free
#undef printf
static void reset(void)
{ assert(!live); owner = (dcp_dev_t){.afk = (void *)1}; creates = destroys = 0;
  fail_allocate = fail_start = fail_interface = fail_shutdown = false; }
static void shutdown_failure(void)
{
    reset(); TYPE *p = CREATE(&owner); assert(p && live == 1); fail_shutdown = true;
    assert(DESTROY(p) < 0 && live == 1);
#ifndef BASELINE
    assert(OWNER(&owner) == p); fail_shutdown = false;
    assert(!DESTROY(p) && !live && !OWNER(&owner)); cases++;
#endif
}
static void partial_init(void)
{
    reset(); fail_interface = fail_shutdown = true;
    assert(!CREATE(&owner) && live == 1);
#ifndef BASELINE
    TYPE *p = OWNER(&owner); assert(p == allocation); fail_shutdown = false;
    assert(!DESTROY(p) && !live && !OWNER(&owner)); cases++;
#endif
}
int main(int argc, char **argv)
{
    assert(argc == 2);
    if (!strcmp(argv[1], "shutdown-failure")) shutdown_failure();
    else if (!strcmp(argv[1], "partial-init")) partial_init();
    else {
        assert(!strcmp(argv[1], "all")); shutdown_failure(); partial_init();
#ifndef BASELINE
        reset(); TYPE *p = CREATE(&owner); assert(p && OWNER(&owner) == p);
        assert(!CREATE(&owner) && creates == 1 && live == 1);
        assert(!DESTROY(p) && !OWNER(&owner) && !live); cases++;
        reset(); fail_allocate = true; assert(!CREATE(&owner) && !creates && !live && !OWNER(&owner)); cases++;
        reset(); fail_start = true; assert(!CREATE(&owner) && !destroys && !live && !OWNER(&owner)); cases++;
        reset(); fail_interface = true; assert(!CREATE(&owner) && destroys == 1 && !live && !OWNER(&owner)); cases++;
        reset(); owner.stopping = true; assert(!CREATE(&owner) && !creates && !live); cases++;
        reset(); assert(!CREATE(NULL) && !DESTROY(NULL) && !live); cases++;
#endif
    }
    printf("client ownership PASS (%u checks)\n", cases); return 0;
}
