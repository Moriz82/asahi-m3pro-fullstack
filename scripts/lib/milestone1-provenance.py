#!/usr/bin/env python3
"""Strict M1 host-role evidence. Checksums need independently retained anchors.

No serial, boot, storage, or firmware access. Only host-identity uses read-only
macOS inventory. Verifiers take an explicit epoch, including historical runs.
"""
import hashlib
import os
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import uuid


def require(ok, message):
    if not ok:
        raise ValueError(message)


def hex64(value):
    require(re.fullmatch(r"[0-9a-f]{64}", value), "missing or invalid independent SHA256/identity")
    return value


def epoch(value):
    require(re.fullmatch(r"[0-9]{1,12}", value), "invalid timestamp")
    return int(value)


def fields(text):
    result = {}
    for line in text.splitlines():
        key, sep, value = line.partition("=")
        require(sep and re.fullmatch(r"[a-z0-9_]+", key) and key not in result,
                "invalid or duplicate manifest key")
        require(value and not any(ord(c) < 32 for c in value), "invalid manifest value")
        result[key] = value
    return result


def sha(data):
    return hashlib.sha256(data).hexdigest()


def tree(root):
    root = Path(root)
    require(root.is_absolute() and not root.is_symlink() and root.is_dir(),
            "evidence requires an absolute, non-symlink directory")
    files = {}
    directories = set()
    for current, dirs, names in os.walk(root, followlinks=False):
        for name in dirs + names:
            path = Path(current) / name
            mode = path.lstat().st_mode
            require(stat.S_ISDIR(mode) or stat.S_ISREG(mode), "non-regular evidence member")
            if stat.S_ISDIR(mode):
                directories.add(path.relative_to(root).as_posix())
            if stat.S_ISREG(mode):
                # Read once: writers copy these verified bytes, not a mutable source tree.
                fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
                with os.fdopen(fd, "rb") as stream:
                    require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "non-regular opened evidence")
                    files[path.relative_to(root).as_posix()] = stream.read()
    parents = {parent.as_posix() for name in files for parent in Path(name).parents if parent != Path(".")}
    require(directories == parents, "empty or undeclared evidence directory")
    return files


def closure(files, names):
    require(set(files) == set(names) | {"SHA256SUMS"}, "missing or unexpected evidence files")
    expected = {}
    for line in files["SHA256SUMS"].splitlines(keepends=True):
        match = re.fullmatch(rb"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)\n", line)
        require(match is not None, "invalid checksum record")
        digest, name = (part.decode("ascii") for part in match.groups())
        require(name in names and name not in expected, "unsafe or duplicate checksum")
        expected[name] = digest
    require(set(expected) == set(names), "incomplete checksum closure")
    require(all(sha(files[name]) == digest for name, digest in expected.items()), "checksum mismatch")


def bundle(files, kind):
    digest = hashlib.sha256(("m1-" + kind + "-v2\0").encode())
    for name, data in sorted(files.items()):
        encoded = name.encode("ascii")
        digest.update(len(encoded).to_bytes(8, "big") + encoded)
        digest.update(len(data).to_bytes(8, "big") + data)
    return digest.hexdigest()


def write(root, values, extra):
    root = Path(root)
    data = dict(extra)
    data["manifest.txt"] = "".join(f"{key}={value}\n" for key, value in values.items()).encode()
    data["SHA256SUMS"] = "".join(f"{sha(value)}  {name}\n" for name, value in sorted(data.items())).encode()
    for name, value in data.items():
        path = root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(value)
    return data


def sub(files, prefix):
    return {name[len(prefix):]: data for name, data in files.items() if name.startswith(prefix)}


def exact(values, expected, variable=()):
    require(set(values) == set(expected) | set(variable), "missing or unexpected manifest keys")
    require(all(values.get(key) == value for key, value in expected.items()), "evidence identity or policy mismatch")


def age(completed, reference, maximum):
    require(0 <= epoch(reference) - epoch(completed) <= int(maximum), "evidence stale or future-dated at reference epoch")


def artifact(text):
    values = fields(text)
    require(set(values) == {"source_commit", "m0_run_id", "m0_manifest_sha256", "image_sha256", "dtb_sha256", "initramfs_sha256"},
            "invalid artifact binding keys")
    require(re.fullmatch(r"[0-9a-f]{40}", values["source_commit"]), "invalid source pin")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", values["m0_run_id"]), "invalid M0 run")
    for key, value in values.items():
        if key.endswith("sha256"):
            hex64(value)
    return values


TARGET_NAMES = {"readiness.log", "manifest.txt"}
CONTROLLER_NAMES = {"manifest.txt"} | {"target-readiness/" + name for name in TARGET_NAMES | {"SHA256SUMS"}}
ROLE_KEYS = ("target_identity_sha256", "controller_identity_sha256", "target_readiness_bundle_sha256",
             "controller_preflight_bundle_sha256", "target_readiness_completed_epoch",
             "controller_preflight_completed_epoch", "target_readiness_max_age_seconds", "preflight_max_age_seconds")


def target(files, identity, digest, reference):
    hex64(identity)
    hex64(digest)
    closure(files, TARGET_NAMES)
    require(bundle(files, "target-readiness") == digest, "target bundle differs from independent anchor")
    values = fields(files["manifest.txt"].decode())
    exact(values, dict(format="2", kind="target-readiness", status="passed", target_model=MODEL,
                       target_board=BOARD, target_identity_sha256=identity, readiness_max_age_seconds=TARGET_AGE,
                       dfu_rehearsed="true", sample_restore_verified="true", producer_exit="0", tee_exit="0",
                       pipe_status="0,0", readiness_script_sha256=SCRIPT_SHA,
                       readiness_sha256=sha(files["readiness.log"])), ("completed_epoch",))
    require(files["readiness.log"], "empty readiness log")
    age(values["completed_epoch"], reference, TARGET_AGE)
    return values


def controller(files, identity, digest, controller_id, device, tool_sha, binding, reference):
    closure(files, CONTROLLER_NAMES)
    hex64(controller_id)
    hex64(tool_sha)
    require(identity != controller_id, "target and controller must be distinct hosts")
    require(re.fullmatch(r"/dev/(cu|tty)\.[A-Za-z0-9._-]+", device), "invalid controller device binding")
    ready = target(sub(files, "target-readiness/"), identity, digest, reference)
    values = fields(files["manifest.txt"].decode())
    expected = artifact(binding)
    expected.update(format="2", kind="controller-preflight", status="passed", preflight_max_age_seconds=CONTROLLER_AGE,
                    target_model=MODEL, target_board=BOARD, target_identity_sha256=identity,
                    controller_identity_sha256=controller_id, target_readiness_bundle_sha256=digest,
                    target_readiness_completed_epoch=ready["completed_epoch"], target_readiness_max_age_seconds=TARGET_AGE,
                    device=device, m1n1_tool_sha256=tool_sha)
    exact(values, expected, ("completed_epoch",))
    age(values["completed_epoch"], reference, CONTROLLER_AGE)
    require(epoch(ready["completed_epoch"]) <= epoch(values["completed_epoch"]), "reversed readiness/preflight order")
    return values


def anchors(path):
    path = Path(path)
    require(path.is_absolute() and ".." not in path.parts, "absolute independent anchor file is required")
    # Open each component relative to a held directory descriptor. Never follow
    # a symlink or re-open a pathname after checking the trust-anchor bytes.
    directory = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            os.close(directory)
            directory = child
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, "rb") as stream:
            require(stat.S_ISREG(os.fstat(stream.fileno()).st_mode), "non-regular anchor file")
            values = stream.read().decode("ascii").splitlines()
    finally:
        os.close(directory)
    require(values and len(set(values)) == len(values), "empty or duplicate anchors")
    return {hex64(value) for value in values}


def execution(files, identity, trusted):
    names = {"manifest.txt", "host.log", "serial.log"} | {"preflight/" + name for name in CONTROLLER_NAMES | {"SHA256SUMS"}}
    closure(files, names)
    values = fields(files["manifest.txt"].decode())
    require(values.get("target_readiness_bundle_sha256") in trusted, "execution target bundle is not independently anchored")
    require(values.get("target_identity_sha256") == hex64(identity), "wrong expected target identity")
    required = set(ROLE_KEYS) | {"execution_id", "execution_started_epoch", "m1n1_tool_sha256", "tool", "device", "command"}
    require(required <= set(values), "missing execution provenance")
    require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}", values["execution_id"]), "invalid execution ID")
    bindings = {key: values.get(key, "") for key in ("source_commit", "m0_run_id", "m0_manifest_sha256", "image_sha256", "dtb_sha256", "initramfs_sha256")}
    preflight = sub(files, "preflight/")
    recorded = controller(preflight, identity, values["target_readiness_bundle_sha256"], values["controller_identity_sha256"],
                          values["device"], values["m1n1_tool_sha256"],
                          "\n".join(f"{k}={v}" for k, v in bindings.items()), values["execution_started_epoch"])
    expected = dict(bindings, format="2", status="completed", compression="none", storage_policy="ram-only",
                    producer_exit="0", tee_exit="0", pipe_status="0,0", exit="0")
    expected.update({key: values[key] for key in required})
    expected.update(controller_preflight_bundle_sha256=bundle(preflight, "controller-preflight"),
                    controller_preflight_completed_epoch=recorded["completed_epoch"],
                    target_readiness_completed_epoch=recorded["target_readiness_completed_epoch"],
                    preflight_max_age_seconds=CONTROLLER_AGE, target_readiness_max_age_seconds=TARGET_AGE)
    exact(values, expected)
    return values


def main(args):
    mode, *args = args
    if mode == "host-identity":
        require(sys.platform == "darwin", "host identity requires macOS")
        role, = args
        require(role in ("target", "controller"), "invalid host role")
        records = plistlib.loads(subprocess.check_output(["/usr/sbin/ioreg", "-a", "-rd1", "-c", "IOPlatformExpertDevice"]))
        require(len(records) == 1, "ambiguous platform identity")
        record = records[0]
        def string(key):
            value = record[key]
            return value.rstrip(b"\0").decode("ascii") if isinstance(value, bytes) else str(value)
        model, board, platform_uuid = string("model"), string("target-type"), string("IOPlatformUUID")
        require(re.fullmatch(r"[A-Za-z0-9,.-]+", model) and re.fullmatch(r"[A-Za-z0-9.-]+", board), "invalid host model/board")
        platform_uuid = str(uuid.UUID(platform_uuid))
        require(platform_uuid != str(uuid.UUID(int=0)), "empty platform UUID")
        if role == "target":
            require((model, board) == (MODEL, BOARD), "wrong target model/board")
        print(sha(("m1-host-identity-v2\0" + model + "\0" + board + "\0" + platform_uuid).encode()))
    elif mode == "target-write":
        root, identity, completed = args
        hex64(identity)
        epoch(completed)
        values = dict(format="2", kind="target-readiness", status="passed", target_model=MODEL, target_board=BOARD,
                      target_identity_sha256=identity, completed_epoch=completed, readiness_max_age_seconds=TARGET_AGE,
                      dfu_rehearsed="true", sample_restore_verified="true", producer_exit="0", tee_exit="0", pipe_status="0,0",
                      readiness_script_sha256=SCRIPT_SHA)
        log = (Path(root) / "readiness.log").read_bytes()
        values["readiness_sha256"] = sha(log)
        files = write(root, values, {"readiness.log": log})
        target(files, identity, bundle(files, "target-readiness"), completed)
    elif mode in ("target-digest", "controller-digest"):
        root, = args
        files = tree(root)
        kind = "target-readiness" if mode == "target-digest" else "controller-preflight"
        closure(files, TARGET_NAMES if mode == "target-digest" else CONTROLLER_NAMES)
        print(bundle(files, kind))
    elif mode == "target-verify":
        root, identity, digest, reference = args
        target(tree(root), identity, digest, reference)
    elif mode == "controller-write":
        root, transfer, identity, digest, controller_id, device, tool_sha, binding, completed = args
        files = tree(transfer)
        ready = target(files, identity, digest, completed)
        values = dict(artifact(binding), format="2", kind="controller-preflight", status="passed", completed_epoch=completed,
                      preflight_max_age_seconds=CONTROLLER_AGE, target_model=MODEL, target_board=BOARD,
                      target_identity_sha256=identity, controller_identity_sha256=controller_id,
                      target_readiness_bundle_sha256=digest, target_readiness_completed_epoch=ready["completed_epoch"],
                      target_readiness_max_age_seconds=TARGET_AGE, device=device, m1n1_tool_sha256=tool_sha)
        saved = write(root, values, {"target-readiness/" + k: v for k, v in files.items()})
        controller(saved, identity, digest, controller_id, device, tool_sha, binding, completed)
    elif mode == "controller-verify":
        root, identity, digest, controller_id, device, tool_sha, binding, reference = args
        controller(tree(root), identity, digest, controller_id, device, tool_sha, binding, reference)
    elif mode == "execution-identity":
        root, started = args
        files = tree(root)
        values = fields(files["manifest.txt"].decode())
        for key in ROLE_KEYS:
            if key == "controller_preflight_bundle_sha256":
                value = bundle(files, "controller-preflight")
            elif key == "controller_preflight_completed_epoch":
                value = values["completed_epoch"]
            else:
                value = values[key]
            print(f"{key}={value}")
        print(f"execution_started_epoch={started}")
        print(f"m1n1_tool_sha256={values['m1n1_tool_sha256']}")
    elif mode in ("execution-verify", "run-verify"):
        root, identity, anchor_path = args
        files = tree(root)
        if mode == "run-verify":
            execution_files = sub(files, "execution/")
            closure(files, {"manifest.txt", "records.tsv"} | {"execution/" + name for name in execution_files})
            values = execution(execution_files, identity, anchors(anchor_path))
            outer = fields(files["manifest.txt"].decode())
            expected = {k: v for k, v in values.items() if k not in ("producer_exit", "tee_exit", "pipe_status", "exit")}
            expected.update(execution_sha256=sha(execution_files["manifest.txt"]), evidence_policy="checksummed-execution-and-serial")
            exact(outer, expected)
            require(files["records.tsv"] == b"1\tsuccess\texecution\tserial.log\n", "invalid enclosing execution record")
        else:
            execution(files, identity, anchors(anchor_path))
    elif mode == "session-identity":
        manifest, identity, anchor_path = args
        anchors(anchor_path)
        values = fields(Path(manifest).read_text())
        require(values.get("format") == "2" and values.get("target_identity_sha256") == hex64(identity), "legacy or wrong-target session")
        hex64(values.get("controller_identity_sha256", ""))
        hex64(values.get("m1n1_tool_sha256", ""))
        require(values["controller_identity_sha256"] != identity, "same-host session")
        require(values.get("target_readiness_max_age_seconds") == TARGET_AGE and
                values.get("preflight_max_age_seconds") == CONTROLLER_AGE, "session policy mismatch")
        required = {"source_commit", "m0_run_id", "m0_manifest_sha256", "image_sha256", "dtb_sha256", "initramfs_sha256",
                    "tool", "device", "command", "target_identity_sha256", "controller_identity_sha256", "m1n1_tool_sha256"}
        require(required <= set(values), "missing session identity")
        exact(values, dict({key: values[key] for key in required}, format="2", status="complete", storage_policy="ram-only",
                           evidence_policy="checksummed-execution-and-serial", target_readiness_max_age_seconds=TARGET_AGE,
                           preflight_max_age_seconds=CONTROLLER_AGE))
    else:
        raise ValueError("unknown evidence operation")


if __name__ == "__main__":
    try:
        MODEL, BOARD, SCRIPT_SHA, TARGET_AGE, CONTROLLER_AGE = sys.argv[1:6]
        hex64(SCRIPT_SHA)
        main(sys.argv[6:])
    except (OSError, ValueError, KeyError, UnicodeError, subprocess.SubprocessError) as error:
        print(f"M1 provenance rejected: {error}", file=sys.stderr)
        sys.exit(1)
