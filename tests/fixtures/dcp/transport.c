/* SPDX-License-Identifier: MIT */
#include <assert.h>
#include <errno.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef uint8_t u8;
typedef uint16_t u16;
typedef uint32_t u32;
typedef uint64_t u64;
#define __packed __attribute__((packed))
#define GENMASK_ULL(hi,lo) ((UINT64_MAX >> (63-(hi))) & (UINT64_MAX << (lo)))
#define BIT_ULL(n) (1ULL << (n))
#define FIELD_GET(mask,x) (((x)&(mask)) >> __builtin_ctzll(mask))
#define FIELD_PREP(mask,x) (((u64)(x) << __builtin_ctzll(mask)) & (mask))
#define ALIGN(x,a) (((x)+(a)-1)&~((a)-1))
#define max(a,b) ((a)>(b) ? (a) : (b))
#define WARN_ON(x) ((void)(x))
#define dev_warn(dev,...) ((void)(dev))
#define trace_iomfb_push(...) ((void)0)
#define IOMFB_ENDPOINT 0x37
#define IOMFB_MAX_CB 1000
#define DCP_FIRMWARE_V_14_7 147
struct apple_dcp;
#include "types.inc"
#ifndef DCP_CHANNEL_SIZE
#define DCP_CHANNEL_SIZE 0x8000
#endif
struct device { int unused; };
typedef bool (*handler_t)(struct apple_dcp *, int, void *, void *);
struct apple_dcp {
    struct device *dev;
    struct dcp_channel ch_cmd, ch_cb, ch_async, ch_oobcmd, ch_oobcb, ch_oobasync;
    void *shmem;
    unsigned fw_compat;
    handler_t *cb_handlers;
};
struct dcp_method_entry { char tag[4]; };
static u64 sent[64];
static unsigned sends, handlers, completions, cases;
static bool defer;
static void *expected_output, *expected_cookie;
static const struct dcp_method_entry method = {{'A','1','2','3'}};
static void dcp_send_message(struct apple_dcp *dcp, unsigned endpoint, u64 message)
{
    assert(dcp && endpoint == IOMFB_ENDPOINT && sends < 64);
    sent[sends++] = message;
}
#include "code.inc"

static bool handle(struct apple_dcp *dcp, int tag, void *out, void *in)
{
    (void)dcp; (void)out; (void)in;
    assert(tag == 123);
    handlers++;
    return !defer;
}
static bool handle_completion(struct apple_dcp *dcp, int tag, void *out, void *in)
{
    (void)dcp; (void)out; (void)in;
    assert(tag == 589);
    handlers++;
    return true;
}
static bool handle_metadata(struct apple_dcp *dcp, int tag, void *out, void *in)
{
    (void)dcp; (void)out; (void)in;
    assert(tag == 6 || tag == 576);
    handlers++;
    return true;
}
static void complete(struct apple_dcp *dcp, void *out, void *cookie)
{
    (void)dcp;
    assert(out == expected_output && cookie == expected_cookie);
    completions++;
}
static handler_t table[IOMFB_MAX_CB] = {[123]=handle};
static struct device device;
static struct apple_dcp dcp;
static u8 *memory, *snapshot;
static void reset(void)
{
    memset(&dcp, 0, sizeof(dcp));
    dcp.dev=&device; dcp.shmem=memory; dcp.fw_compat=DCP_FIRMWARE_V_14_7; dcp.cb_handlers=table;
    memset(memory, 0xa5, DCP_SHMEM_SIZE);
    sends=handlers=completions=0; defer=false;
}
static void packet(enum dcp_context_id context, u16 offset, u32 in_len, u32 out_len)
{
    struct dcp_packet_header header = {{'3','2','1','D'},in_len,out_len};
    assert(dcp_channel_offset(context)>=0);
    memcpy(memory+dcp_channel_offset(context)+offset,&header,sizeof(header));
}
static void rx(enum dcp_context_id context, u16 offset, u32 length, bool ack)
{
    dcpep_got_msg(&dcp, dcpep_msg(context,length,offset) | (ack ? IOMFB_MSG_ACK : 0));
}
static void unchanged(struct apple_dcp *before, unsigned old_sends, unsigned old_handlers)
{
    assert(!memcmp(before,&dcp,sizeof(dcp)));
    assert(!memcmp(snapshot,memory,DCP_SHMEM_SIZE));
    assert(sends==old_sends && handlers==old_handlers);
    cases++;
}
static void reject_rx(enum dcp_context_id context, u16 offset, u32 length, bool ack)
{
    struct apple_dcp before=dcp;
    memcpy(snapshot,memory,DCP_SHMEM_SIZE);
    unsigned old_sends=sends, old_handlers=handlers;
    rx(context,offset,length,ack);
    unchanged(&before,old_sends,old_handlers);
}
static void reject_push(bool oob, u32 in_len, u32 out_len, void *input)
{
    struct apple_dcp before=dcp;
    memcpy(snapshot,memory,DCP_SHMEM_SIZE);
    unsigned old_sends=sends, old_handlers=handlers;
    dcp_push(&dcp,oob,&method,in_len,out_len,input,NULL,NULL);
    unchanged(&before,old_sends,old_handlers);
}
static void nested_window(bool oob)
{
    reset();
    enum dcp_context_id ctx=oob ? DCP_CONTEXT_OOBCB : DCP_CONTEXT_CB;
    struct dcp_channel *ch=dcp_get_channel(&dcp,ctx);
    dcp_push(&dcp,oob,&method,0,500,NULL,NULL,NULL);
    assert(sends==1 && FIELD_GET(IOMFB_MSG_OFFSET,sent[0])==0);
    packet(ctx,0,0,4); defer=true;
    rx(ctx,0,16,false);
    assert(ch->depth==1 && handlers==1);
    u8 original[512]; memcpy(original,memory+dcp_tx_offset(ctx),sizeof(original));
    dcp_push(&dcp,oob,&method,0,4,NULL,complete,&dcp);
    assert(sends==2 && ch->depth==2);
    assert(FIELD_GET(IOMFB_MSG_OFFSET,sent[1])==512);
    assert(!memcmp(original,memory+dcp_tx_offset(ctx),sizeof(original)));
    expected_output=memory+dcp_tx_offset(ctx)+524; expected_cookie=&dcp;
    /* No offset/length in ACK; output comes from the saved TX frame. */
    rx(ctx,0,0,true);
    assert(ch->depth==1 && completions==1);
    dcp_ack(&dcp,ctx);
    assert(ch->depth==0 && sends==3);
    rx(oob ? DCP_CONTEXT_OOBCMD : DCP_CONTEXT_CMD,0,0,true);
    assert(!dcp.ch_cmd.depth && !dcp.ch_oobcmd.depth);
    cases++;
}
static void ack_pointer(void)
{
    reset();
    dcp_push(&dcp,false,&method,0,8,NULL,complete,&dcp);
    expected_output=memory+12; expected_cookie=&dcp;
    /* Returned headers are not authoritative for the output address. */
    struct dcp_packet_header *header=(void *)memory;
    header->in_len=UINT32_MAX;
    rx(DCP_CONTEXT_CMD,0,0,true);
    assert(completions==1 && !dcp.ch_cmd.depth);
    cases++;
}
static void deferred_complete(struct apple_dcp *target, void *out, void *cookie)
{
    complete(target,out,cookie);
    struct dcp_channel *ch=&target->ch_cb;
    assert(ch->depth==1);
    *(u8 *)ch->output[ch->depth-1]=1;
    dcp_ack(target,DCP_CONTEXT_CB);
}
static void reentrant_complete(struct apple_dcp *target, void *out, void *cookie)
{
    complete(target,out,cookie);
    dcp_push(target,false,&method,0,8,NULL,complete,cookie);
}
static void deferred_roundtrip(bool root_command)
{
    reset();
    if (root_command) dcp_push(&dcp,false,&method,0,256,NULL,NULL,NULL);
    packet(DCP_CONTEXT_CB,0,0,4); defer=true;
    rx(DCP_CONTEXT_CB,0,16,false);
    dcp_push(&dcp,false,&method,0,8,NULL,deferred_complete,&dcp);
    enum dcp_context_id ctx=root_command ? DCP_CONTEXT_CB : DCP_CONTEXT_CMD;
    struct dcp_channel *ch=dcp_get_channel(&dcp,ctx);
    expected_output=ch->output[ch->depth-1]; expected_cookie=&dcp;
    rx(ctx,0,0,true);
    assert(completions==1 && !dcp.ch_cb.depth && memory[0x6000c]==1);
    if (root_command) rx(DCP_CONTEXT_CMD,0,0,true);
    assert(!dcp.ch_cmd.depth); cases++;
}
static void interleaved_windows(void)
{
    reset(); defer=true;
    dcp_push(&dcp,false,&method,0,500,NULL,NULL,NULL);
    packet(DCP_CONTEXT_CB,0,0,4); rx(DCP_CONTEXT_CB,0,16,false);
    dcp_push(&dcp,false,&method,0,4,NULL,NULL,NULL);
    /* RX offset 64 is valid even with a TX frame ending at 576. */
    packet(DCP_CONTEXT_CB,64,0,4); rx(DCP_CONTEXT_CB,64,16,false);
    assert(dcp.ch_cb.depth==3 && handlers==2);
    dcp_push(&dcp,false,&method,0,4,NULL,NULL,NULL);
    assert(FIELD_GET(IOMFB_MSG_OFFSET,sent[2])==576);
    rx(DCP_CONTEXT_CB,0,0,true);
    dcp_ack(&dcp,DCP_CONTEXT_CB);
    rx(DCP_CONTEXT_CB,0,0,true);
    dcp_ack(&dcp,DCP_CONTEXT_CB);
    rx(DCP_CONTEXT_CMD,0,0,true);
    assert(!dcp.ch_cmd.depth && !dcp.ch_cb.depth); cases++;
    reset();
    expected_output=memory+12; expected_cookie=&dcp;
    dcp_push(&dcp,false,&method,0,8,NULL,reentrant_complete,&dcp);
    rx(DCP_CONTEXT_CMD,0,0,true);
    assert(completions==1 && sends==2 && dcp.ch_cmd.depth==1);
    rx(DCP_CONTEXT_CMD,0,0,true);
    assert(completions==2 && !dcp.ch_cmd.depth); cases++;
}
static void completion_contract(void)
{
    const enum dcp_context_id contexts[] = {
        DCP_CONTEXT_CB, DCP_CONTEXT_ASYNC, DCP_CONTEXT_OOBCB, DCP_CONTEXT_OOBASYNC,
    };
    const u32 sizes[] = {0, 4, 1751, 1752, 1775, 1777, 2048};
    table[589] = handle_completion;
    for (unsigned i = 0; i < 4; i++) {
        enum dcp_context_id context = contexts[i];
        for (unsigned j = 0; j < sizeof(sizes) / sizeof(sizes[0]); j++) {
            reset(); packet(context, 0, sizes[j], 0);
            memcpy(memory + dcp_channel_offset(context), "985D", 4);
            reject_rx(context, 0, 12 + sizes[j], false);
        }
        for (unsigned output = 1; output <= 4; output++) {
            reset(); packet(context, 0, 1776, output);
            memcpy(memory + dcp_channel_offset(context), "985D", 4);
            reject_rx(context, 0, 1788 + output, false);
        }
        reset(); packet(context, 0, 1776, 0);
        memcpy(memory + dcp_channel_offset(context), "985D", 4);
        reject_rx(context, 0, 1787, false);
        reject_rx(context, 0, 1789, false);
        memcpy(snapshot, memory, DCP_SHMEM_SIZE);
        rx(context, 0, 1788, false);
        assert(handlers == 1 && sends == 1 && !dcp_get_channel(&dcp, context)->depth);
        assert(!memcmp(snapshot, memory, DCP_SHMEM_SIZE));
        cases++;
        /* Preserve existing acceptance for the earlier firmware profiles. */
        for (unsigned version = 123; version <= 133; version += 10) {
            reset(); dcp.fw_compat = version; packet(context, 0, 1752, 0);
            memcpy(memory + dcp_channel_offset(context), "985D", 4);
            rx(context, 0, 1764, false);
            assert(handlers == 1 && sends == 1); cases++;
        }
    }
    table[589] = NULL;
}
static void metadata_contract(void)
{
    const enum dcp_context_id contexts[] = {
        DCP_CONTEXT_CB, DCP_CONTEXT_ASYNC, DCP_CONTEXT_OOBCB, DCP_CONTEXT_OOBASYNC,
    };
    const unsigned tags[] = {6, 576};
    const char *wire_tags[] = {"600D", "675D"};
    const u32 input[] = {60, 88}, output[] = {56, 76};
    for (unsigned t = 0; t < 2; t++) {
        table[tags[t]] = handle_metadata;
        for (unsigned c = 0; c < 4; c++) {
            enum dcp_context_id context = contexts[c];
            for (unsigned kind = 0; kind < 9; kind++) {
                u32 in_len = input[t], out_len = output[t];
                if (kind == 0) in_len = 0;
                if (kind == 1) in_len--;
                if (kind == 2) in_len++;
                if (kind == 3) out_len = 0;
                if (kind == 4) out_len--;
                if (kind == 5) out_len++;
                if (kind == 6) { in_len--; out_len++; }
                reset(); packet(context, 0, in_len, out_len);
                memcpy(memory + dcp_channel_offset(context), wire_tags[t], 4);
                u32 length = 12 + in_len + out_len;
                if (kind == 7) length--;
                if (kind == 8) length++;
                reject_rx(context, 0, length, false);
            }
            reset(); packet(context, 0, input[t], output[t]);
            memcpy(memory + dcp_channel_offset(context), wire_tags[t], 4);
            memcpy(snapshot, memory, DCP_SHMEM_SIZE);
            memset(snapshot + dcp_channel_offset(context) + 12 + input[t], 0, output[t]);
            rx(context, 0, 12 + input[t] + output[t], false);
            assert(handlers == 1 && sends == 1 && !dcp_get_channel(&dcp, context)->depth);
            assert(!memcmp(snapshot, memory, DCP_SHMEM_SIZE)); cases++;
            for (unsigned version = 123; version <= 133; version += 10) {
                reset(); dcp.fw_compat = version;
                packet(context, 0, t ? 8 : 32, t ? 0 : 28);
                memcpy(memory + dcp_channel_offset(context), wire_tags[t], 4);
                rx(context, 0, t ? 20 : 72, false);
                assert(handlers == 1 && sends == 1); cases++;
            }
        }
        table[tags[t]] = NULL;
    }
}
int main(int argc, char **argv)
{
    assert(argc==2 && sizeof(struct dcp_packet_header)==12);
    memory=malloc(DCP_SHMEM_SIZE); snapshot=malloc(DCP_SHMEM_SIZE);
    assert(memory && snapshot); reset();
    if (!strcmp(argv[1],"empty-ack")) {
        reject_rx(DCP_CONTEXT_CMD,0,0,true);
    } else if (!strcmp(argv[1],"deep-callback")) {
        packet(DCP_CONTEXT_CB,0,0,4); dcp.ch_cb.depth=DCP_MAX_CALL_DEPTH;
        reject_rx(DCP_CONTEXT_CB,0,16,false);
    } else if (!strcmp(argv[1],"short-payload")) {
        packet(DCP_CONTEXT_CB,0,0,64);
        reject_rx(DCP_CONTEXT_CB,0,12,false);
    } else if (!strcmp(argv[1],"nested-window")) {
        nested_window(false);
    } else if (!strcmp(argv[1],"ack-pointer")) {
        ack_pointer();
    } else if (!strcmp(argv[1],"short-completion")) {
        table[589] = handle_completion;
        packet(DCP_CONTEXT_CB, 0, 4, 0);
        memcpy(memory + dcp_channel_offset(DCP_CONTEXT_CB), "985D", 4);
        reject_rx(DCP_CONTEXT_CB, 0, 16, false);
    } else if (!strcmp(argv[1],"trailing-completion")) {
        table[589] = handle_completion;
        packet(DCP_CONTEXT_CB, 0, 1776, 0);
        memcpy(memory + dcp_channel_offset(DCP_CONTEXT_CB), "985D", 4);
        reject_rx(DCP_CONTEXT_CB, 0, 1789, false);
    } else if (!strcmp(argv[1], "short-frame-sync") || !strcmp(argv[1], "short-hotplug") ||
               !strcmp(argv[1], "trailing-frame-sync") || !strcmp(argv[1], "trailing-hotplug")) {
        bool hotplug = strstr(argv[1], "hotplug") != NULL;
        bool trailing = !strncmp(argv[1], "trailing", 8);
        unsigned tag = hotplug ? 576 : 6;
        u32 input = trailing ? (hotplug ? 88 : 60) : 4;
        u32 output = hotplug ? 76 : 56;
        table[tag] = handle_metadata;
        packet(DCP_CONTEXT_CB, 0, input, output);
        memcpy(memory + dcp_channel_offset(DCP_CONTEXT_CB), hotplug ? "675D" : "600D", 4);
        reject_rx(DCP_CONTEXT_CB, 0, 12 + input + output + trailing, false);
    } else {
        assert(!strcmp(argv[1],"all"));
        for (unsigned ctx=0; ctx<16; ctx++) {
            reset();
            reject_rx(ctx,0,0,true);
            struct apple_dcp before=dcp;
            dcp_ack(&dcp,ctx);
            assert(!memcmp(&before,&dcp,sizeof(dcp)) && !sends); cases++;
            if (ctx!=0 && ctx!=3 && ctx!=4 && ctx!=7)
                reject_rx(ctx,0,12,false);
        }
        const enum dcp_context_id contexts[]={DCP_CONTEXT_CB,DCP_CONTEXT_OOBCB,DCP_CONTEXT_ASYNC,DCP_CONTEXT_OOBASYNC};
        const u32 bad_lengths[]={0,1,11,DCP_CHANNEL_SIZE+1,UINT32_MAX};
        const u16 bad_offsets[]={1,63,DCP_CHANNEL_SIZE,DCP_CHANNEL_SIZE+64,UINT16_MAX};
        for (unsigned c=0; c<4; c++) {
            enum dcp_context_id ctx=contexts[c];
            for (unsigned i=0; i<sizeof(bad_lengths)/sizeof(bad_lengths[0]); i++) {
                reset(); packet(ctx,0,0,4); reject_rx(ctx,0,bad_lengths[i],false);
            }
            for (unsigned i=0; i<sizeof(bad_offsets)/sizeof(bad_offsets[0]); i++) {
                reset(); reject_rx(ctx,bad_offsets[i],12,false);
            }
            for (unsigned which=0; which<2; which++) {
                for (unsigned length=1; length<=65; length++) {
                    reset(); packet(ctx,0,which ? 0 : length,which ? length : 0);
                    reject_rx(ctx,0,12,false);
                }
                reset(); packet(ctx,0,which ? 0 : UINT32_MAX,which ? UINT32_MAX : 0);
                reject_rx(ctx,0,12,false);
            }
            for (unsigned depth=DCP_MAX_CALL_DEPTH; depth<=UINT8_MAX; depth++) {
                reset(); packet(ctx,0,0,4); dcp_get_channel(&dcp,ctx)->depth=depth;
                reject_rx(ctx,0,16,false);
                if (depth>DCP_MAX_CALL_DEPTH) reject_rx(ctx,0,0,true);
            }
            reset(); packet(ctx,DCP_CHANNEL_SIZE-64,3,49);
            rx(ctx,DCP_CHANNEL_SIZE-64,64,false);
            assert(handlers==1 && sends==1 && !dcp_get_channel(&dcp,ctx)->depth);
            u8 *payload=memory+dcp_channel_offset(ctx)+DCP_CHANNEL_SIZE-49;
            for (unsigned i=0; i<49; i++) assert(payload[i]==0);
            assert(payload[-1]==0xa5 && payload[49]==0xa5); cases++;
            reset(); packet(ctx,DCP_CHANNEL_SIZE-64,0,0);
            reject_rx(ctx,DCP_CHANNEL_SIZE-64,65,false);
            reset(); defer=true;
            for (unsigned depth=0; depth<DCP_MAX_CALL_DEPTH; depth++) {
                packet(ctx,depth*64,0,4); rx(ctx,depth*64,16,false);
                assert(dcp_get_channel(&dcp,ctx)->depth==depth+1); cases++;
            }
            packet(ctx,8*64,0,4); reject_rx(ctx,8*64,16,false);
            for (unsigned depth=DCP_MAX_CALL_DEPTH; depth>0; depth--) {
                dcp_ack(&dcp,ctx); assert(dcp_get_channel(&dcp,ctx)->depth==depth-1); cases++;
            }
            reset(); defer=true; packet(ctx,0,0,64); rx(ctx,0,76,false);
            reject_rx(ctx,64,16,false); /* occupied RX extent */
            reject_rx(ctx,0,0,true);   /* remote ACK cannot pop callback */
            reset(); dcp.shmem=NULL; reject_rx(ctx,0,16,false); reject_rx(ctx,0,0,true);
            reset(); packet(ctx,0,0,4); table[123]=NULL; reject_rx(ctx,0,16,false); table[123]=handle;
            reset(); packet(ctx,0,0,4); dcp.cb_handlers=NULL; reject_rx(ctx,0,16,false);
        }
        for (unsigned oob=0; oob<2; oob++) {
            reset(); dcp.shmem=NULL; reject_push(oob,0,0,NULL);
            reset(); reject_push(oob,1,0,NULL);
            reject_push(oob,UINT32_MAX,0,memory); reject_push(oob,0,UINT32_MAX,NULL);
            reject_push(oob,DCP_CHANNEL_SIZE-12,1,memory);
            reset(); dcp_push(&dcp,oob,&method,0,DCP_CHANNEL_SIZE-12,NULL,NULL,NULL);
            assert(sends==1 && FIELD_GET(IOMFB_MSG_LENGTH,sent[0])==DCP_CHANNEL_SIZE); cases++;
            reject_push(oob,0,0,NULL);
            reset();
            for (unsigned depth=0; depth<=DCP_MAX_CALL_DEPTH; depth++) {
                dcp_push(&dcp,oob,&method,0,4,NULL,NULL,NULL);
                assert(sends==depth+1); cases++;
            }
            reject_push(oob,0,4,NULL);
            enum dcp_context_id ctx=oob ? DCP_CONTEXT_OOBCB : DCP_CONTEXT_CB;
            for (unsigned depth=DCP_MAX_CALL_DEPTH; depth>0; depth--) {
                rx(ctx,UINT16_MAX,UINT32_MAX,true);
                assert(dcp_get_channel(&dcp,ctx)->depth==depth-1); cases++;
            }
            rx(oob ? DCP_CONTEXT_OOBCMD : DCP_CONTEXT_CMD,0,0,true);
            for (unsigned which=0; which<2; which++) {
                for (unsigned depth=DCP_MAX_CALL_DEPTH+1; depth<=UINT8_MAX; depth++) {
                    reset();
                    struct dcp_channel *ch=which ? (oob ? &dcp.ch_oobcb : &dcp.ch_cb) : (oob ? &dcp.ch_oobcmd : &dcp.ch_cmd);
                    ch->depth=depth; reject_push(oob,0,0,NULL);
                }
            }
            nested_window(oob);
        }
        ack_pointer();
        deferred_roundtrip(false); deferred_roundtrip(true); interleaved_windows();
        for (unsigned character=0; character<4; character++) {
            reset(); packet(DCP_CONTEXT_CB,0,0,4);
            memory[0x60000+character]='X'; reject_rx(DCP_CONTEXT_CB,0,16,false);
        }
        /* Real D408 dispatcher rejection remains upstream of handler execution. */
        reset(); packet(DCP_CONTEXT_CB,0,0,4); memory[0x60000]='8'; memory[0x60001]='0'; memory[0x60002]='4';
        table[408]=handle; reject_rx(DCP_CONTEXT_CB,0,16,false); table[408]=NULL;
        /* Ordinary inputs and output reservation retain adjacent sentinels. */
        reset();
        u32 input=0xfeedbeef;
        dcp_push(&dcp,false,&method,sizeof(input),8,&input,complete,&input);
        assert(!memcmp(memory+12,&input,4) && memory[24]==0xa5);
        struct dcp_packet_header *header=(void *)memory;
        assert(!memcmp(header->tag,"321A",4) && header->in_len==4 && header->out_len==8);
        expected_output=memory+16; expected_cookie=&input; rx(DCP_CONTEXT_CMD,0,0,true);
        assert(completions==1); cases++;
        completion_contract();
        metadata_contract();
    }
    free(snapshot); free(memory);
    printf("PASS: %u transport cases; actual C, fake mailbox/callbacks\n",cases);
}
