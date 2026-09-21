#!/usr/bin/env python3
"""Run pinned PMGR/DART C excerpts in an offline AArch64 Linux container.

This is a source-behavior tier, not a kernel build, module load, or hardware
test. It uses the source volume's existing shared/exclusive build lock.
"""
import argparse
import contextlib
import fcntl
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(data):
    return hashlib.sha256(data).hexdigest()


def between(source, start, end):
    require(source.count(start) == source.count(end) == 1, "source extraction boundary drift")
    begin, finish = source.index(start), source.index(end)
    require(begin < finish, "reversed source extraction boundaries")
    return begin, source[begin:finish]


def macro(source, name):
    matches = list(re.finditer(r"^#define " + re.escape(name) + r"\(", source, re.M))
    require(len(matches) == 1, "missing or duplicate polling macro: " + name)
    begin = matches[0].start()
    finish = begin
    for line in source[begin:].splitlines(keepends=True):
        finish += len(line)
        if not line.rstrip().endswith("\\"):
            return begin, source[begin:finish]
    raise ValueError("unterminated polling macro")


def located(path, source, excerpt):
    begin, text = excerpt
    line = source.count("\n", 0, begin) + 1
    return f"#line {line} {json.dumps(str(path))}\n{text}\n"


def validate_paths(source, output):
    require(source.is_absolute() and source.resolve() == source and source.is_dir(), "source must be an absolute physical directory")
    require(output.is_absolute() and output.parent.resolve() == output.parent and output.parent.is_dir(), "output parent must be an absolute physical directory")
    require(not output.exists() and not output.is_symlink(), "output already exists")
    require(source not in output.parents, "output must be outside the source tree")


@contextlib.contextmanager
def locked_source(source, commit):
    # The build lock is opened, never created/replaced, and held through publish.
    with (source.parent / ".milestone0-build.lock").open("rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_SH | fcntl.LOCK_NB)
        require(subprocess.check_output(["git", "-C", str(source), "rev-parse", "HEAD"], text=True).strip() == commit,
                "Linux source is not at the current post-patch M0 pin")
        require(not subprocess.check_output(["git", "-C", str(source), "status", "--porcelain", "--untracked-files=all"], text=True),
                "Linux source is not clean")
        yield


def run(command, stage, log, expected=0):
    with (stage / log).open("wb") as output:
        result = subprocess.run(command, cwd=stage, stdout=output, stderr=subprocess.STDOUT, timeout=90)
    text = (stage / log).read_text()
    require(result.returncode == expected, f"unexpected exit {result.returncode} for {command[0]}:\n{text[-8000:]}")
    return text


def publish(stage, output, publisher):
    for path in stage.iterdir():
        path.chmod(path.stat().st_mode & ~0o222)
    stage.chmod(0o500)
    try:
        subprocess.run(["bash", "-Eeuo", "pipefail", "-c",
                        'source "$1"; evidence_atomic_publish_directory "$2" "$3"',
                        "publish", str(publisher), str(stage), str(output)], check=True)
    finally:
        # Failed publication must leave the private stage removable; there are
        # no fallible permission changes after the atomic no-replace rename.
        if stage.exists():
            stage.chmod(0o700)


def validate_driver_result(kind, result):
    expected = {
        "pmgr": "preliminary_fault_policy=logs_error_then_returns_final_transition_status\n"
                "pmgr_behavior_cases=85 passed; hardware_acceptance=false",
        "dart": "dart_behavior_cases=195 passed; hardware_acceptance=false",
    }
    require(result.strip() == expected[kind], "unexpected behavior-case summary: " + kind)


def validate_coverage(coverage):
    expected = {"apple_pmgr_" + name for name in ("ps_set", "ps_is_active", "ps_power_on", "ps_power_off",
                                                 "reset_assert", "reset_deassert", "reset_reset", "reset_status")}
    expected.update("apple_dart_" + name for name in ("t8020_hw_stream_command", "t8110_hw_tlb_command", "t8020_irq", "t8110_irq"))
    records = [re.fullmatch(r"function (apple_\w+) called ([1-9][0-9]*) returned 100% blocks executed ([1-9][0-9]?|100)%", row)
               for row in coverage]
    require(len(records) == len(expected) and all(records) and {record[1] for record in records} == expected,
            "missing, duplicate, unexecuted, or unexpected selected-function coverage")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-dir", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    require(sys.platform == "linux" and platform.machine() == "aarch64" and Path("/.dockerenv").is_file(),
            "requires the documented offline AArch64 Linux container")
    source, output = args.source_dir, args.out
    validate_paths(source, output)
    project = Path(__file__).resolve().parents[1]
    config = (project / "config/milestone0.env").read_text()
    pins = re.findall(r"^LINUX_SOURCE_TREE_COMMIT=([0-9a-f]{40})$", config, re.M)
    require(len(pins) == 1, "missing or duplicate Linux source pin")
    commit = pins[0]
    contract = (project / "config/milestone2-source-files.sha256").read_text()
    require(f"# source_tree_commit={commit}\n" in contract, "M2 contract/source pin mismatch")

    with locked_source(source, commit):
        paths = {"pmgr": "drivers/pmdomain/apple/pmgr-pwrstate.c", "dart": "drivers/iommu/apple-dart.c",
                 "iopoll": "include/linux/iopoll.h", "regmap": "include/linux/regmap.h",
                 "target": "arch/arm64/boot/dts/apple/t6030.dtsi", "domains": "arch/arm64/boot/dts/apple/t6030-pmgr.dtsi"}
        texts = {key: (source / path).read_text() for key, path in paths.items()}
        # Also bind polling headers to Git objects, independently of status and
        # the narrower M2 contract; assume-unchanged must not conceal drift.
        for key, path in paths.items():
            require(texts[key].encode() == subprocess.check_output(["git", "-C", str(source), "show", f"{commit}:{path}"]),
                    "source bytes differ from pinned Git object: " + path)
        for key in ("pmgr", "dart", "target", "domains"):
            require(f"{digest(texts[key].encode())}  {paths[key]}\n" in contract, "M2 file contract mismatch: " + paths[key])
        require('"apple,t6030-dart", "apple,t8110-dart"' in texts["target"], "target DART backend drift")
        require(not re.search(r"apple,force-(disable|reset)", texts["domains"]), "PMGR fragment force-flag coverage must be reviewed")

        with tempfile.TemporaryDirectory(prefix=".m2-driver-", dir=output.parent) as temporary:
            stage = Path(temporary)
            pmgr = located(source / paths["pmgr"], texts["pmgr"], between(texts["pmgr"], "#define APPLE_PMGR_RESET ", "static const struct reset_control_ops apple_pmgr_reset_ops"))
            dart = "".join(located(source / paths["dart"], texts["dart"], between(texts["dart"], start, end)) for start, end in (
                ("#define DART_MAX_STREAMS ", "struct apple_dart_atomic_stream_map {"),
                ("static int\napple_dart_t8020_hw_stream_command", "static int\napple_dart_t8020_hw_invalidate_tlb"),
                ("static irqreturn_t apple_dart_t8020_irq", "static irqreturn_t apple_dart_irq")))
            polls = "".join(located(source / paths["iopoll"], texts["iopoll"], macro(texts["iopoll"], name)) for name in (
                "poll_timeout_us_atomic", "read_poll_timeout_atomic", "readx_poll_timeout_atomic", "readl_poll_timeout_atomic"))
            polls += located(source / paths["regmap"], texts["regmap"], macro(texts["regmap"], "regmap_read_poll_timeout_atomic"))
            for name, text in (("pmgr-snippet.h", pmgr), ("dart-snippet.h", dart), ("poll-snippet.h", polls)):
                (stage / name).write_text(text)
            (stage / "harness.c").write_bytes((project / "tests/m2-driver-self-test.c").read_bytes())
            (stage / "runner.py").write_bytes(Path(__file__).read_bytes())
            flags = ["gcc", "-std=gnu11", "-g", "-Wall", "-Wextra", "-Werror", "-Wno-unused-function", "-Wno-unused-parameter",
                     "-Wno-sign-compare", "-I", str(stage)]
            summaries = []
            for kind in ("pmgr", "dart"):
                defines = ["-DTEST_PMGR"] if kind == "pmgr" else []
                run(flags + ["-O2", "-fsanitize=address,undefined", "-fno-sanitize-recover=all", "-fno-omit-frame-pointer"] +
                    defines + ["harness.c", "-o", kind + "-test"], stage, kind + "-compile.log")
                result = run(["./" + kind + "-test"], stage, kind + "-test.log").strip()
                validate_driver_result(kind, result)
                summaries.append(result)
                run(flags + ["-O0", "--coverage"] + defines + ["harness.c", "-o", kind + "-coverage"], stage, kind + "-coverage-compile.log")
                validate_driver_result(kind, run(["./" + kind + "-coverage"], stage, kind + "-coverage-run.log"))
                run(["gcov", "-f", "-b", "-c", kind + "-coverage-harness.gcno"], stage, kind + "-gcov.log")
            # Counterfactual policies must fail: a preliminary error cannot
            # replace a proven final power state or cause an unrolled-back abort.
            propagated = pmgr
            for before, after in (
                ("\tint ret;\n\tstruct apple_pmgr_ps *ps = genpd_to_apple_pmgr_ps(genpd);",
                 "\tint ret, preliminary_ret = 0;\n\tstruct apple_pmgr_ps *ps = genpd_to_apple_pmgr_ps(genpd);"),
                ("\t\t\t\tgenpd->name, reg);\n\t}", "\t\t\t\tgenpd->name, reg);\n\t\tpreliminary_ret = ret;\n\t}"),
                ("\treturn ret;\n}\n\nstatic bool", "\treturn ret ?: preliminary_ret;\n}\n\nstatic bool")):
                require(propagated.count(before) == 1, "preliminary-errno mutation boundary drift")
                propagated = propagated.replace(before, after)
            mutations = (
                ("pmgr-preliminary-errno", "pmgr", pmgr, propagated, "ret == expected_ret"),
                ("pmgr-preliminary-abort", "pmgr", "\t\t\t\tgenpd->name, reg);\n\t}",
                 "\t\t\t\tgenpd->name, reg);\n\t\tif (ret < 0)\n\t\t\treturn ret;\n\t}", "ret == expected_ret"),
                ("pmgr-target", "pmgr", "reg |= FIELD_PREP(APPLE_PMGR_PS_TARGET, pstate);", "reg |= FIELD_PREP(APPLE_PMGR_PS_MIN, pstate);",
                 "writes[prep] == (retained | target)"),
                ("pmgr-error", "pmgr", "\treturn ret;\n}\n\nstatic bool", "\treturn 0;\n}\n\nstatic bool",
                 "apple_pmgr_ps_power_on(&fixture.genpd) == (failure ? -EIO : -ETIMEDOUT)"),
                ("dart-timeout", "dart", "\t\tif (ret)\n\t\t\tbreak;", "\t\tif (false)\n\t\t\tbreak;",
                 "apple_dart_t8110_hw_tlb_command(&streams, DART_T8110_TLB_CMD_OP_FLUSH_SID) == -ETIMEDOUT"),
                ("dart-ack", "dart", "writel(U32_MAX, dart->regs + DART_T8110_ERROR_STREAMS", "writel(0, dart->regs + DART_T8110_ERROR_STREAMS",
                 "events[bank + 1].value == UINT32_MAX"))
            for name, kind, before, after, assertion in mutations:
                original = pmgr if kind == "pmgr" else dart
                require(original.count(before) == 1, "mutation boundary drift: " + name)
                header = stage / (kind + "-snippet.h")
                header.write_text(original.replace(before, after))
                defines = ["-DTEST_PMGR"] if kind == "pmgr" else []
                run(flags + ["-O2"] + defines + ["harness.c", "-o", name + "-mutant"], stage, name + "-compile.log")
                result = run(["./" + name + "-mutant"], stage, name + "-negative.log", expected=1)
                require(f"check failed: {assertion} at " in result, "mutation failed for an unrelated reason: " + name)
                header.write_text(original)
                summaries.append(name + "_mutation=rejected")
            coverage = []
            for path in stage.glob("*.gcov"):
                for line in path.read_text().splitlines():
                    if line.startswith("function apple_"):
                        coverage.append(line)
            validate_coverage(coverage)
            (stage / "coverage-summary.txt").write_text("\n".join(sorted(coverage)) + "\n")
            (stage / "source-inputs.sha256").write_text("".join(f"{digest(texts[key].encode())}  {paths[key]}\n" for key in paths))
            compiler = subprocess.check_output(["gcc", "--version"], text=True).splitlines()[0]
            manifest = f"format=1\nsource_tree_commit={commit}\ncompiler={compiler}\nhardware_acceptance=false\ncanonical_evidence=false\n"
            manifest += "source_scope=verbatim-selected-driver-functions-and-polling-macros\n"
            manifest += "preliminary_fault_policy=logs-error-then-returns-final-transition-status\n"
            (stage / "manifest.txt").write_text(manifest)
            (stage / "SHA256SUMS").write_text("".join(f"{digest(path.read_bytes())}  {path.name}\n" for path in sorted(stage.iterdir()) if path.is_file()))
            publish(stage, output, project / "scripts/lib/evidence.sh")
            print("\n".join(summaries + sorted(coverage)))
            print(f"m2_driver_source_tests=passed evidence={output}\nhardware_acceptance=false")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"M2 driver-source test failed: {error}", file=sys.stderr)
        sys.exit(1)
