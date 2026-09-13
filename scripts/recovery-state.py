#!/usr/bin/env python3
"""Atomic, checksummed snapshots and one-boot reset provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import sys
import tempfile
import time

SCHEMA = 1


def fail(message: str) -> "NoReturn":
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def digest(path: pathlib.Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def read_identity(path: str, label: str) -> str:
    try:
        value = pathlib.Path(path).read_text(encoding="utf-8").strip()
    except OSError as exc:
        fail(f"cannot read {label} at {path}: {exc}")
    if not value:
        fail(f"{label} is empty at {path}")
    return value


def safe_logical(value: str) -> pathlib.PurePosixPath:
    logical = pathlib.PurePosixPath(value)
    if logical.is_absolute() or ".." in logical.parts or str(logical) in ("", "."):
        fail(f"unsafe snapshot path: {value}")
    return logical


def parse_file(value: str) -> tuple[pathlib.PurePosixPath, pathlib.Path]:
    if "=" not in value:
        fail(f"snapshot file must be logical=source: {value}")
    logical, source = value.split("=", 1)
    return safe_logical(logical), pathlib.Path(source)


def atomic_json(path: pathlib.Path, value: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as output:
            json.dump(value, output, sort_keys=True, indent=2)
            output.write("\n")
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
    finally:
        try:
            os.unlink(temporary)
        except FileNotFoundError:
            pass


def load_json(path: pathlib.Path, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"invalid {label} at {path}: {exc}")
    if not isinstance(value, dict):
        fail(f"invalid {label} at {path}: expected object")
    return value


def verify_release(release: pathlib.Path, component: str) -> dict:
    manifest = load_json(release / "manifest.json", "snapshot manifest")
    if manifest.get("schema") != SCHEMA or manifest.get("component") != component:
        fail(f"snapshot manifest does not describe {component}")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        fail("snapshot manifest contains no files")
    actual_files = {
        str(path.relative_to(release))
        for path in release.rglob("*")
        if path.is_file() and path.name != "manifest.json"
    }
    if actual_files != set(files):
        fail("snapshot contents do not exactly match its manifest")
    for logical, metadata in files.items():
        safe_logical(logical)
        target = release / logical
        if target.is_symlink() or not target.is_file() or not isinstance(metadata, dict):
            fail(f"snapshot is missing {logical}")
        if metadata.get("sha256") != digest(target):
            fail(f"snapshot checksum mismatch for {logical}")
        if metadata.get("mode") != target.stat().st_mode & 0o777:
            fail(f"snapshot mode mismatch for {logical}")
    expected_id = hashlib.sha256(
        json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()
    if release.name != expected_id:
        fail("snapshot directory does not match its manifest")
    return manifest


def current_release(base: pathlib.Path, component: str) -> pathlib.Path:
    current = base / "current"
    if not current.is_symlink():
        fail(f"no validated current snapshot at {current}")
    release = current.resolve(strict=True)
    try:
        release.relative_to((base / "releases").resolve())
    except ValueError:
        fail("current snapshot points outside releases")
    verify_release(release, component)
    return release


def cmd_create(args: argparse.Namespace) -> None:
    base = pathlib.Path(args.persist).resolve()
    releases = base / "releases"
    releases.mkdir(parents=True, exist_ok=True)
    entries = [parse_file(value) for value in args.file]
    if not entries:
        fail("refusing to create an empty snapshot")
    logical_names = [str(logical) for logical, _ in entries]
    if len(logical_names) != len(set(logical_names)):
        fail("duplicate logical snapshot path")

    stage = pathlib.Path(tempfile.mkdtemp(prefix=".staging.", dir=releases))
    try:
        files = {}
        for logical, source in entries:
            if not source.is_file():
                fail(f"required live source is missing: {source}")
            target = stage / logical
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
            files[str(logical)] = {
                "mode": target.stat().st_mode & 0o777,
                "sha256": digest(target),
            }
        manifest = {"schema": SCHEMA, "component": args.component, "files": files}
        release_id = hashlib.sha256(
            json.dumps(manifest, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()
        atomic_json(stage / "manifest.json", manifest)
        release = releases / release_id
        if release.exists():
            verify_release(release, args.component)
        else:
            os.replace(stage, release)
            stage = None

        temporary_link = base / f".current-{os.getpid()}"
        try:
            temporary_link.symlink_to(pathlib.Path("releases") / release_id)
            os.replace(temporary_link, base / "current")
        finally:
            temporary_link.unlink(missing_ok=True)
        print(release)
    finally:
        if stage is not None:
            shutil.rmtree(stage, ignore_errors=True)


def cmd_verify(args: argparse.Namespace) -> None:
    print(current_release(pathlib.Path(args.persist).resolve(), args.component))


def cmd_prepare(args: argparse.Namespace) -> None:
    base = pathlib.Path(args.persist).resolve()
    release = current_release(base, args.component)
    provenance = {
        "schema": SCHEMA,
        "component": args.component,
        "release": release.name,
        "machine_id_sha256": hashlib.sha256(
            read_identity(args.machine_id_file, "machine id").encode()
        ).hexdigest(),
        "boot_id": read_identity(args.boot_id_file, "boot id"),
        "created_at": int(time.time()),
    }
    atomic_json(base / "reset-provenance.json", provenance)
    print(base / "reset-provenance.json")


def validated_provenance(
    args: argparse.Namespace,
) -> tuple[pathlib.Path, pathlib.Path, dict, str]:
    base = pathlib.Path(args.persist).resolve()
    provenance_path = pathlib.Path(
        args.provenance or base / "reset-provenance.json"
    ).resolve()
    provenance = load_json(provenance_path, "reset provenance")
    if provenance.get("schema") != SCHEMA or provenance.get("component") != args.component:
        fail(f"reset provenance does not describe {args.component}")
    created_at = provenance.get("created_at")
    if not isinstance(created_at, int) or time.time() - created_at > args.max_age:
        fail("reset provenance is stale")
    machine_hash = hashlib.sha256(
        read_identity(args.machine_id_file, "machine id").encode()
    ).hexdigest()
    if provenance.get("machine_id_sha256") != machine_hash:
        fail("reset provenance belongs to a different machine")
    current_boot = read_identity(args.boot_id_file, "boot id")
    if provenance.get("boot_id") == current_boot:
        fail("reset provenance predates no observed reboot; recovery is ambiguous")
    claimed_boot = provenance.get("recovery_boot_id")
    if claimed_boot is not None and claimed_boot != current_boot:
        fail("reset provenance was already claimed by a different recovery boot")
    release_id = provenance.get("release")
    if not isinstance(release_id, str) or len(release_id) != 64:
        fail("reset provenance has an invalid release id")
    release = base / "releases" / release_id
    verify_release(release, args.component)
    return provenance_path, release, provenance, current_boot


def cmd_verify_provenance(args: argparse.Namespace) -> None:
    provenance_path, release, provenance, current_boot = validated_provenance(args)
    if "recovery_boot_id" not in provenance:
        provenance["recovery_boot_id"] = current_boot
        atomic_json(provenance_path, provenance)
    print(release)


def cmd_consume(args: argparse.Namespace) -> None:
    provenance_path, release, provenance, current_boot = validated_provenance(args)
    if provenance.get("recovery_boot_id") != current_boot:
        fail("reset provenance has not been claimed by this recovery boot")
    consumed = provenance_path.with_name(
        f"reset-provenance.consumed-{int(time.time())}-{release.name[:12]}.json"
    )
    os.replace(provenance_path, consumed)
    print(consumed)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    for command in ("create", "verify", "prepare", "verify-provenance", "consume"):
        sub = subparsers.add_parser(command)
        sub.add_argument("--component", required=True)
        sub.add_argument("--persist", required=True)
        if command == "create":
            sub.add_argument("--file", action="append", default=[])
        if command in ("prepare", "verify-provenance", "consume"):
            sub.add_argument("--machine-id-file", required=True)
            sub.add_argument("--boot-id-file", required=True)
        if command in ("verify-provenance", "consume"):
            sub.add_argument("--provenance")
            sub.add_argument("--max-age", type=int, default=7 * 24 * 60 * 60)
    return result


def main() -> None:
    args = parser().parse_args()
    {
        "create": cmd_create,
        "verify": cmd_verify,
        "prepare": cmd_prepare,
        "verify-provenance": cmd_verify_provenance,
        "consume": cmd_consume,
    }[args.command](args)


if __name__ == "__main__":
    main()
