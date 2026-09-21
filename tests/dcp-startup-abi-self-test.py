#!/usr/bin/env python3
"""Actual Linux startup/callback source: APPLE_DRIVER [--baseline|--completion-baseline]."""
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
    return section(text, "struct " + name + " {", "} __packed;") + "} __packed;\n"


def main():
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] not in ("--baseline", "--completion-baseline")):
        raise SystemExit(__doc__)
    driver = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3
    completion_only = baseline and sys.argv[2] == "--completion-baseline"
    common = (driver / "iomfb.h").read_text()
    header = (driver / "iomfb_template.h").read_text()
    source = (driver / "iomfb_template.c").read_text()
    code = declaration(common, "dcp_iouserclient") + declaration(common, "dcp_set_power_state_resp")
    for name in ("dcp_swap_start_req", "dcp_swap_start_resp", "dcp_set_power_state_req"):
        versioned = "DCP_FW_NAME(" + name + ")"
        code += declaration(header, versioned) if "struct " + versioned + " {" in header else declaration(common, name)
    code += declaration(header, "DCP_FW_NAME(dc_swap_complete_resp)")
    code += section(common, "enum dcpep_method {", "\n#define IOMFB_MAX_CB")
    macros = (driver / "iomfb_internal.h").read_text()
    code += section(macros, "#define DCP_THUNK_INOUT(", "\n#define IOMFB_THUNK_INOUT")
    code += section(macros, "#define TRAMPOLINE_IN(", "\n#define TRAMPOLINE_INOUT")
    thunks = []
    for name in ("dcp_swap_start", "dcp_set_power_state", "dcp_enable_disable_video_power_savings"):
        matches = re.findall(r"DCP_THUNK_INOUT\(" + name + r",[\s\S]*?\);", source)
        if len(matches) != 1:
            raise ValueError(f"missing/ambiguous actual thunk: {name}")
        thunks += matches
    thunks += [section(source, "static void dcpep_cb_swap_complete(", "\n/* special */")]
    matches = re.findall(r"TRAMPOLINE_IN\(trampoline_swap_complete,[\s\S]*?\);", source)
    if len(matches) != 1:
        raise ValueError("missing/ambiguous actual completion trampoline")
    thunks += matches
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise RuntimeError("existing compiler required")
    env = dict(os.environ, ASAN_OPTIONS="detect_leaks=" + ("0" if sys.platform == "darwin" else "1"))
    with tempfile.TemporaryDirectory(prefix="dcp-startup-abi-") as name:
        temporary = Path(name)
        (temporary / "types.inc").write_text(code)
        (temporary / "thunks.inc").write_text("\n".join(thunks))
        for major, minor in ([(14, 7)] if baseline else [(12, 3), (13, 3), (14, 7)]):
            table = (driver / f"iomfb_v{major}_{minor}.c").read_text()
            (temporary / "table.inc").write_text(section(table, "static const struct dcp_method_entry dcp_methods", "\n#define DCP_FW"))
            executable = temporary / "startup"
            command = [compiler, "-std=c11", "-Wall", "-Wextra", "-Werror", "-g",
                       "-Wno-unused-parameter",
                       "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                       f"-DDCP_FW_VER=(({major}<<16)|({minor}<<8))", "-I", str(temporary),
                       str(Path(__file__).parent / "fixtures/dcp/startup-abi.c"), "-o", str(executable)]
            # Baseline lacks the additional fields; do not invent them in source.
            if baseline:
                command += ["-DCOMPLETION_BASELINE" if completion_only else "-DBASELINE"]
            subprocess.run(command, check=True)
            for mode in (["completion"] if completion_only else ["swap", "power", "tag", "completion"] if baseline else ["all"]):
                result = subprocess.run([str(executable), mode], capture_output=True, text=True, env=env)
                if baseline:
                    expected = {"swap": "A406 request size", "power": "A472 null flag offset", "tag": "power-saving method tag", "completion": "D589 structure size"}[mode]
                    if result.returncode == 0 or expected not in result.stderr:
                        raise AssertionError(f"missing predecessor failure {mode}: {result.stderr}")
                    print(f"PASS: predecessor {mode} mismatch reproduced")
                elif result.returncode or result.stderr:
                    raise AssertionError(result.stderr)
                else:
                    print(f"{major}.{minor}: {result.stdout.strip()}")


if __name__ == "__main__":
    main()
