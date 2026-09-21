#!/usr/bin/env python3
"""Actual D006/D576 Linux callbacks: APPLE_DRIVER [--baseline]. No target I/O."""
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f"ambiguous source section: {start}")
    return start + text.split(start, 1)[1].split(end, 1)[0]


def declaration(text, name):
    # Old frame_sync_props alone is not explicitly packed.
    match = re.search(r"struct " + re.escape(name) + r" \{[\s\S]*?\n\}(?: __packed)?;", text)
    if not match:
        raise ValueError(f"missing declaration: {name}")
    return match[0] + "\n"


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--baseline"):
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3
    common = (driver / "iomfb.h").read_text()
    header = (driver / "iomfb_template.h").read_text()
    source = (driver / "iomfb_template.c").read_text()
    macros = (driver / "iomfb_internal.h").read_text()
    code = ""
    for name in ("frame_sync_props", "dcp_set_frame_sync_props_req", "dcp_set_frame_sync_props_resp"):
        versioned = "DCP_FW_NAME(" + name + ")"
        code += declaration(header, versioned) if "struct " + versioned + " {" in header else declaration(common, name)
    has_hotplug = "struct DCP_FW_NAME(dcp_hotplug_req) {" in header
    if has_hotplug:
        code += "#if NEW_ABI\n"
        for name in ("dcp_hotplug_req", "dcp_hotplug_resp"):
            code += declaration(header, "DCP_FW_NAME(" + name + ")")
        code += "#endif\n"
    code += section(macros, "#define TRAMPOLINE_IN(", "\n#define TRAMPOLINE_OUT(")
    frame_start = ("static struct DCP_FW_NAME(dcp_set_frame_sync_props_resp)" if
                   "static struct DCP_FW_NAME(dcp_set_frame_sync_props_resp)" in source
                   else "static struct dcp_set_frame_sync_props_resp")
    callbacks = section(source, frame_start, "\n/* Callback to get the current time")
    callbacks += section(source, "static void dcpep_cb_hotplug(", "\nstatic void\ndcpep_cb_swap_complete_intent_gated(")
    callbacks += re.search(r"TRAMPOLINE_INOUT\(trampoline_set_frame_sync_props,[\s\S]*?\);", source)[0] + "\n"
    if has_hotplug:
        callbacks += "#if NEW_ABI\n"
        callbacks += re.search(r"TRAMPOLINE_INOUT\(trampoline_hotplug,[\s\S]*?\);", source)[0]
        callbacks += "\n#else\n"
    callbacks += re.search(r"TRAMPOLINE_IN\(trampoline_hotplug,[\s\S]*?\);", source)[0] + "\n"
    if has_hotplug:
        callbacks += "#endif\n"
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise RuntimeError("existing compiler required")
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=" + ("0" if sys.platform == "darwin" else "1"))
    with tempfile.TemporaryDirectory(prefix="dcp-metadata-") as name:
        temporary = Path(name)
        (temporary / "types.inc").write_text(code)
        (temporary / "callbacks.inc").write_text(callbacks)
        for major, minor in ([(14, 7)] if baseline else [(12, 3), (13, 3), (14, 7)]):
            table = (driver / f"iomfb_v{major}_{minor}.c").read_text()
            entries = re.findall(r"^\s*\[(6|576)\]\s*=\s*(\w+)\s*,", table, re.M)
            if len({key for key, value in entries}) != len(entries):
                raise ValueError("duplicate metadata callback registration")
            (temporary / "table.inc").write_text(
                "static handler_t table[577] = {\n" +
                "".join(f"[{key}] = {value},\n" for key, value in entries) + "};\n")
            executable = temporary / "metadata"
            command = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-g",
                       "-Wno-unused-parameter", "-Wno-unused-function",
                       "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                       f"-DDCP_FW_VER=(({major}<<16)|({minor}<<8))", "-I", str(temporary),
                       str(Path(__file__).parent / "fixtures/dcp/metadata.c"), "-o", str(executable)]
            if has_hotplug:
                command += ["-DMETADATA_HAS_HOTPLUG"]
            subprocess.run(command, check=True)
            for mode in (["frame-layout", "frame-reply", "hotplug-reply"] if baseline else ["all"]):
                result = subprocess.run([str(executable), mode], capture_output=True, text=True, env=env)
                if baseline:
                    if result.returncode == 0 or mode not in result.stderr:
                        raise AssertionError(f"missing predecessor {mode} failure: {result.stderr}")
                    print(f"PASS: predecessor {mode} fault reproduced")
                elif result.returncode or result.stderr:
                    raise AssertionError(result.stderr)
                else:
                    print(f"{major}.{minor}: {result.stdout.strip()}")


if __name__ == "__main__":
    main()
