#!/usr/bin/env python3
"""Execute the two real DCP null-initialization snippets on owned memory only.

Usage: python3 -B tests/dcp-null-flags-self-test.py /prepared/drivers/gpu/drm/apple
This is bounded snippet coverage, not execution of a kernel driver or firmware.
"""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def extract(source, function, marker):
    start = source.index("void DCP_FW_NAME(" + function + ")")
    end = source.find("\nvoid DCP_FW_NAME(", start + 1)
    body = source[start:end if end >= 0 else len(source)]
    if body.count(marker) != 1:
        raise ValueError("ambiguous initialization marker")
    block = body.split(marker, 1)[1].split("#endif", 1)[0] + "#endif"
    if function == "iomfb_poweroff" and "memset(swap, 0, sizeof(*swap));" not in body:
        raise ValueError("poweroff zero-initialization precondition changed")
    return block


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    source = (Path(sys.argv[1]) / "iomfb_template.c").read_text()
    off = extract(source, "iomfb_poweroff", "/* Null all surfaces */")
    flush = extract(source, "iomfb_flush", "/* Reset all surfaces to defaults */")
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise RuntimeError("C compiler required")
    cases = 0
    with tempfile.TemporaryDirectory(prefix="dcp-null-flags-") as tmp:
        for version, count in ((12, 5), (13, 5), (14, 6)):
            for mutation in ("none", "poweroff-five", "flush-five"):
                if version != 14 and mutation != "none":
                    continue
                off_case, flush_case = off, flush
                if mutation == "poweroff-five":
                    old = "ARRAY_SIZE(swap->surf2_null)"
                    if off_case.count(old) != 1:
                        raise ValueError("poweroff mutation site changed")
                    off_case = off_case.replace(old, "5")
                elif mutation == "flush-five":
                    old = "ARRAY_SIZE(req->surf2_null)"
                    if flush_case.count(old) != 1:
                        raise ValueError("flush mutation site changed")
                    flush_case = flush_case.replace(old, "5")
                code = f'''
#include <stdbool.h>
#include <string.h>
#define ARRAY_SIZE(a) (sizeof(a)/sizeof((a)[0]))
#define SWAP_SURFACES 4
#define DCP_FW_VERSION(x,y,z) (((x)<<16)|((y)<<8)|(z))
#define DCP_FW_VER DCP_FW_VERSION({version}, {7 if version == 14 else 3}, 0)
struct request {{
    bool surf_null[4], surf2_null[{count}];
    bool unkU32Ptr_null, unkU32out_null;
}};
static void poweroff(struct request *swap) {{
    memset(swap, 0, sizeof(*swap));
    {off_case}
}}
static void flush(struct request *req) {{
    int l;
    {flush_case}
}}
static int check(void (*init)(struct request *)) {{
    struct {{ unsigned char before[16]; struct request req; unsigned char after[16]; }} owned;
    memset(&owned, 0xa5, sizeof(owned));
    init(&owned.req);
    for (int i=0; i<16; i++) if (owned.before[i]!=0xa5 || owned.after[i]!=0xa5) return 1;
    for (int i=0; i<4; i++) if (!owned.req.surf_null[i]) return 1;
    for (int i=0; i<{count}; i++) if (owned.req.surf2_null[i] != ({version} >= 13)) return 1;
    if (owned.req.unkU32Ptr_null != ({version} >= 13)) return 1;
    if (owned.req.unkU32out_null != ({version} >= 13)) return 1;
    return 0;
}}
int main(void) {{ return check(poweroff) | (check(flush) << 1); }}
'''
                src, exe = Path(tmp) / "case.c", Path(tmp) / "case"
                src.write_text(code)
                subprocess.run([compiler, "-std=c11", "-Wall", "-Wextra", "-Werror",
                                "-Wno-sign-compare", "-fsanitize=undefined", "-fno-sanitize-recover=all",
                                str(src), "-o", str(exe)], check=True, capture_output=True)
                result = subprocess.run([str(exe)], capture_output=True)
                expected = {"none": 0, "poweroff-five": 1, "flush-five": 2}[mutation]
                if result.returncode != expected or result.stderr:
                    raise AssertionError((version, mutation, result.returncode, result.stderr))
                cases += 1
    print(f"PASS: {cases} compiled cases; both paths, legacy and six-slot layouts, two negative controls")


if __name__ == "__main__":
    main()
