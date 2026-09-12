#!/usr/bin/env python3

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import os
import pathlib
import stat
import sys
from collections.abc import Mapping
from typing import Any, BinaryIO


CHUNK_SIZE = 8 * 1024 * 1024


class ManifestError(ValueError):
    """Raised when an artifact tree or manifest is malformed or unsafe."""


@dataclasses.dataclass(frozen=True)
class ManifestFile:
    path: str
    size: int
    sha256: str


@dataclasses.dataclass(frozen=True)
class ArtifactManifest:
    version: int
    files: tuple[ManifestFile, ...]


@dataclasses.dataclass(frozen=True)
class Finding:
    path: str
    code: str
    summary: str


def _stream_digest(stream: BinaryIO) -> str:
    digest = hashlib.sha256()
    while True:
        chunk = stream.read(CHUNK_SIZE)
        if not chunk:
            return digest.hexdigest()
        digest.update(chunk)


def _file_digest(path: pathlib.Path) -> str:
    try:
        with path.open("rb") as stream:
            return _stream_digest(stream)
    except OSError as exc:
        raise ManifestError(f"cannot hash artifact file {path}: {exc}") from exc


def _safe_relative_path(value: str) -> pathlib.PurePosixPath | None:
    if not isinstance(value, str) or not value:
        return None
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or path == pathlib.PurePosixPath("."):
        return None
    if ".." in path.parts or str(path) != value:
        return None
    return path


def _walk_regular_files(root: pathlib.Path) -> list[pathlib.Path]:
    try:
        root_mode = root.lstat().st_mode
    except OSError as exc:
        raise ManifestError(f"cannot access artifact root {root}: {exc}") from exc
    if not stat.S_ISDIR(root_mode):
        raise ManifestError("artifact root must be a plain directory")

    files: list[pathlib.Path] = []
    pending = [root]
    while pending:
        directory = pending.pop()
        try:
            entries = sorted(os.scandir(directory), key=lambda entry: entry.name)
        except OSError as exc:
            raise ManifestError(f"cannot scan artifact directory {directory}: {exc}") from exc
        for entry in entries:
            path = pathlib.Path(entry.path)
            try:
                mode = entry.stat(follow_symlinks=False).st_mode
            except OSError as exc:
                raise ManifestError(f"cannot inspect artifact path {path}: {exc}") from exc
            if stat.S_ISLNK(mode):
                raise ManifestError(f"artifact tree contains a symlink: {path}")
            if stat.S_ISDIR(mode):
                pending.append(path)
            elif stat.S_ISREG(mode):
                files.append(path)
            else:
                raise ManifestError(f"artifact path is not a regular file: {path}")
    return sorted(files, key=lambda path: path.relative_to(root).as_posix())


def build_manifest(root: pathlib.Path) -> ArtifactManifest:
    artifact_root = pathlib.Path(root)
    entries = []
    for path in _walk_regular_files(artifact_root):
        relative = path.relative_to(artifact_root).as_posix()
        entries.append(
            ManifestFile(
                path=relative,
                size=path.stat(follow_symlinks=False).st_size,
                sha256=_file_digest(path),
            )
        )
    return ArtifactManifest(version=1, files=tuple(entries))


def canonical_manifest_bytes(manifest: ArtifactManifest) -> bytes:
    if not isinstance(manifest, ArtifactManifest) or manifest.version != 1:
        raise ManifestError("manifest must be a version 1 ArtifactManifest")
    value = {
        "version": manifest.version,
        "files": [dataclasses.asdict(entry) for entry in manifest.files],
    }
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as exc:
        raise ManifestError(f"manifest cannot be encoded canonically: {exc}") from exc
    return encoded.encode("utf-8") + b"\n"


def _load_json(path: pathlib.Path) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ManifestError(f"duplicate manifest key: {key}")
            result[key] = value
        return result

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                ManifestError(f"non-finite manifest value: {value}")
            ),
        )
    except OSError as exc:
        raise ManifestError(f"cannot read manifest {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise ManifestError(f"manifest is not valid JSON: {exc}") from exc


def load_manifest(path: pathlib.Path) -> ArtifactManifest:
    value = _load_json(pathlib.Path(path))
    if not isinstance(value, Mapping) or set(value) != {"version", "files"}:
        raise ManifestError("manifest must contain exactly version and files")
    if value["version"] != 1 or not isinstance(value["files"], list):
        raise ManifestError("manifest version or files collection is invalid")

    entries = []
    for index, raw_entry in enumerate(value["files"]):
        if not isinstance(raw_entry, Mapping) or set(raw_entry) != {
            "path",
            "size",
            "sha256",
        }:
            raise ManifestError(f"manifest file {index} has invalid fields")
        relative = _safe_relative_path(raw_entry["path"])
        size = raw_entry["size"]
        digest = raw_entry["sha256"]
        if relative is None:
            raise ManifestError(f"manifest file {index} has an unsafe path")
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise ManifestError(f"manifest file {index} has an invalid size")
        if (
            not isinstance(digest, str)
            or len(digest) != 64
            or any(character not in "0123456789abcdef" for character in digest)
        ):
            raise ManifestError(f"manifest file {index} has an invalid SHA-256")
        entries.append(ManifestFile(str(relative), size, digest))

    paths = [entry.path for entry in entries]
    if paths != sorted(paths) or len(set(paths)) != len(paths):
        raise ManifestError("manifest file paths must be unique and sorted")
    return ArtifactManifest(version=1, files=tuple(entries))


def verify_manifest(
    root: pathlib.Path,
    manifest: ArtifactManifest,
) -> list[Finding]:
    artifact_root = pathlib.Path(root)
    findings: list[Finding] = []
    expected_paths: set[str] = set()
    for entry in manifest.files:
        relative = _safe_relative_path(entry.path)
        if relative is None:
            findings.append(
                Finding(entry.path, "unsafe_path", "manifest path is unsafe")
            )
            continue
        expected_paths.add(entry.path)
        path = artifact_root.joinpath(*relative.parts)
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            findings.append(Finding(entry.path, "missing", "artifact file is missing"))
            continue
        except OSError:
            findings.append(
                Finding(entry.path, "unreadable", "artifact file cannot be inspected")
            )
            continue
        if not stat.S_ISREG(mode):
            findings.append(
                Finding(entry.path, "not_regular", "artifact path is not a regular file")
            )
            continue
        actual_size = path.stat(follow_symlinks=False).st_size
        if actual_size != entry.size:
            findings.append(
                Finding(entry.path, "size_mismatch", "artifact size does not match")
            )
        try:
            actual_digest = _file_digest(path)
        except ManifestError:
            findings.append(
                Finding(entry.path, "unreadable", "artifact file cannot be hashed")
            )
            continue
        if actual_digest != entry.sha256:
            findings.append(
                Finding(entry.path, "digest_mismatch", "artifact digest does not match")
            )

    try:
        actual_paths = {
            path.relative_to(artifact_root).as_posix()
            for path in _walk_regular_files(artifact_root)
        }
    except ManifestError as exc:
        findings.append(Finding(".", "unsafe_tree", str(exc)))
        return findings
    for unexpected in sorted(actual_paths - expected_paths):
        findings.append(
            Finding(unexpected, "unexpected", "artifact file is not in the manifest")
        )
    return findings


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="artifact_manifest.py")
    subparsers = parser.add_subparsers(dest="command", required=True)
    build_parser = subparsers.add_parser("build")
    build_parser.add_argument("root", type=pathlib.Path)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("root", type=pathlib.Path)
    verify_parser.add_argument("manifest", type=pathlib.Path)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = _build_parser().parse_args(arguments)
    try:
        if options.command == "build":
            sys.stdout.buffer.write(canonical_manifest_bytes(build_manifest(options.root)))
            return 0
        manifest = load_manifest(options.manifest)
        findings = verify_manifest(options.root, manifest)
        print(
            json.dumps(
                [dataclasses.asdict(finding) for finding in findings],
                separators=(",", ":"),
                sort_keys=True,
            )
        )
        return 1 if findings else 0
    except ManifestError as exc:
        print(f"artifact_manifest: error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
