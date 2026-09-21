#!/usr/bin/env python3
"""Actual dt_set_display alias/dispatch test: SOURCE [DTB | --baseline]."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile


def section(text, start, end):
    if text.count(start) != 1 or end not in text.split(start, 1)[1]:
        raise ValueError(f"ambiguous source section: {start}")
    return start + text.split(start, 1)[1].split(end, 1)[0]


def main():
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    source = Path(sys.argv[1]).resolve(strict=True)
    baseline = len(sys.argv) == 3 and sys.argv[2] == "--baseline"
    dtb = str(Path(sys.argv[2]).resolve(strict=True)) if len(sys.argv) == 3 and not baseline else None
    text = (source / "src/kboot.c").read_text()
    selected = {"mapping-struct": ("struct disp_mapping {", "\nstruct mem_region {"),
                "mapping-arrays": ("static struct disp_mapping disp_reserved_regions_t8103[]", "\nstatic int dt_set_display_clocks(void)"),
                "display": ("static int dt_set_display(void)", "\nstatic const char *excluded_pmp_props[]")}
    compiler = shutil.which("clang") or shutil.which("cc")
    if not compiler:
        raise RuntimeError("existing compiler required")
    libfdt = source / "src/libfdt"
    with tempfile.TemporaryDirectory(prefix="display-alias-") as name:
        temporary = Path(name)
        for key, bounds in selected.items():
            (temporary / (key + ".inc")).write_text(section(text, *bounds) + "\n")
        executable = temporary / "alias-test"
        command = [compiler, "-std=c11", "-D_POSIX_C_SOURCE=200809L", "-Wall", "-Wextra", "-Werror", "-g",
                   "-fsanitize=address,undefined", "-fno-sanitize-recover=all",
                   "-I", str(temporary), "-I", str(libfdt), str(Path(__file__).with_suffix(".c"))]
        command += [str(libfdt / (p + ".c")) for p in
                    ("fdt", "fdt_ro", "fdt_rw", "fdt_wip", "fdt_sw", "fdt_empty_tree", "fdt_strerror")]
        subprocess.run(command + ["-o", str(executable)], check=True)
        env = dict(os.environ, ASAN_OPTIONS="detect_leaks=" + ("0" if sys.platform == "darwin" else "1"))
        args = ["baseline"] if baseline else [dtb] if dtb else []
        result = subprocess.run([str(executable), *args], text=True, capture_output=True, env=env)
        if baseline:
            if result.returncode == 0 or "canonical PIODMA alias selection" not in result.stderr:
                raise AssertionError(f"missing expected alias regression: {result.returncode}: {result.stderr}")
            print(json.dumps({"predecessor_alias_failure": "reproduced"}))
        else:
            if result.returncode or result.stderr:
                raise AssertionError(f"{result.returncode}: {result.stderr}")
            print(result.stdout.strip())


if __name__ == "__main__":
    main()
