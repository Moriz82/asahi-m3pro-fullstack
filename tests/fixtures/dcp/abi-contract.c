// SPDX-License-Identifier: MIT
/* Offline compile-only contract from T6030 23J220 A407 at 0x13f500. */
#include "iomfb_v12_3.h"
#include "iomfb_v13_3.h"
#include "iomfb_v14_7.h"
#include <linux/build_bug.h>
#include <linux/stddef.h>

#define REQ struct dcp_swap_submit_req_v14_7_0
#define RESP struct dcp_swap_submit_resp_v14_7_0
#define OFFSET(field, value) static_assert(offsetof(REQ, field) == (value), #field)
static_assert(sizeof(struct dcp_swap_v14_7_0) == 1288, "swap record");
static_assert(sizeof(struct dcp_surface_v14_7_0) == 556, "surface stride");
static_assert(sizeof(REQ) == 7000, "A407 input");
static_assert(sizeof(RESP) == 12, "A407 output aligned to four bytes");
static_assert(offsetof(RESP, ret) == 5, "A407 return status");
OFFSET(surf, 1288);
OFFSET(surf_iova, 3512);
OFFSET(unk_u64_a, 3544);
OFFSET(surf2, 3576);
OFFSET(surf2_iova, 6912);
OFFSET(unkbool, 6960);
OFFSET(unkdouble, 6961);
OFFSET(unkU64, 6969);
OFFSET(unkbool2, 6977);
OFFSET(clear, 6978);
OFFSET(unkU32Ptr, 6982);
OFFSET(swap_null, 6986);
OFFSET(surf_null, 6987);
OFFSET(surf2_null, 6991);
OFFSET(unkoutbool_null, 6997);
OFFSET(unkU32Ptr_null, 6998);
OFFSET(unkU32out_null, 6999);
static_assert(ARRAY_SIZE(((REQ *)0)->surf2) == 6, "secondary surface count");
static_assert(ARRAY_SIZE(((REQ *)0)->surf2_iova) == 6, "secondary IOVA count");
static_assert(ARRAY_SIZE(((REQ *)0)->surf2_null) == 6, "secondary null count");
