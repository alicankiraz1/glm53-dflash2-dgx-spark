#!/usr/bin/env python3

"""Hugging Face snapshot cache verification against two explicit contracts.

Hub snapshot manifest (``kind == "hub"``)::

    {"revision": "<40 hex>", "files": {"<relative path>": "<digest>"}}

This is the authoritative shape published for a Hub revision. It carries no
file sizes, so every entry must be verified by content: a 40 hex digest is a
Git blob SHA-1 whose hash input includes the byte length, and a 64 hex digest
is the SHA-256 of the full LFS object. Because sizes are not part of this
contract, hub verification refuses to run without blob hashing rather than
silently skipping the size check.

Artifact snapshot manifest (``kind == "artifact"``)::

    {"version": 1, "repository": "<owner>/<name>", "revision": "<40 hex>",
     "files": [{"path": "<relative path>", "size": <int>, "sha256": "<digest>"}]}

This is the deterministic manifest this package produces itself. Every entry
declares a size, and every declared size is enforced.
"""

from __future__ import annotations

import argparse
import dataclasses
import hashlib
import json
import pathlib
import stat
import sys
from collections.abc import Mapping
from typing import Any, BinaryIO


CHUNK_SIZE = 8 * 1024 * 1024
HUB_MANIFEST_KIND = "hub"
ARTIFACT_MANIFEST_KIND = "artifact"


class CacheVerificationError(RuntimeError):
    """Raised when cache metadata is malformed or escapes its repository."""


@dataclasses.dataclass(frozen=True)
class CacheFinding:
    path: str
    code: str
    summary: str


@dataclasses.dataclass(frozen=True)
class ManifestEntry:
    size: int | None
    digest: str


@dataclasses.dataclass(frozen=True)
class SnapshotManifest:
    kind: str
    repository: str | None
    revision: str
    files: Mapping[str, ManifestEntry]


def _load_json(path: pathlib.Path) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise CacheVerificationError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    try:
        return json.loads(
            path.read_text(encoding="utf-8"),
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                CacheVerificationError(f"non-finite JSON value: {value}")
            ),
        )
    except OSError as exc:
        raise CacheVerificationError(f"cannot read JSON file {path}: {exc}") from exc
    except json.JSONDecodeError as exc:
        raise CacheVerificationError(f"invalid JSON file {path}: {exc}") from exc


def _update_hash(stream: BinaryIO, hasher: Any) -> None:
    while True:
        chunk = stream.read(CHUNK_SIZE)
        if not chunk:
            return
        hasher.update(chunk)


def _file_digest(path: pathlib.Path, expected: str) -> str:
    try:
        if len(expected) == 64:
            hasher = hashlib.sha256()
        elif len(expected) == 40:
            hasher = hashlib.sha1()
            hasher.update(f"blob {path.stat().st_size}\0".encode("ascii"))
        else:
            raise CacheVerificationError("manifest digest must be SHA-1 or SHA-256")
        with path.open("rb") as stream:
            _update_hash(stream, hasher)
        return hasher.hexdigest()
    except OSError as exc:
        raise CacheVerificationError(f"cannot hash cache file {path}: {exc}") from exc


def _safe_manifest_path(value: Any) -> pathlib.PurePosixPath:
    if not isinstance(value, str) or not value:
        raise CacheVerificationError("manifest path must be a non-empty string")
    path = pathlib.PurePosixPath(value)
    if path.is_absolute() or ".." in path.parts or str(path) != value:
        raise CacheVerificationError(f"unsafe manifest path: {value}")
    return path


def _validate_digest(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) not in {40, 64}
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise CacheVerificationError("manifest contains an invalid blob digest")
    return value


def _validate_revision(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 40
        or any(character not in "0123456789abcdef" for character in value)
    ):
        raise CacheVerificationError("snapshot manifest revision is invalid")
    return value


def _load_hub_manifest(payload: Mapping[str, Any]) -> SnapshotManifest:
    files_value = payload["files"]
    if not isinstance(files_value, Mapping) or not files_value:
        raise CacheVerificationError("hub snapshot manifest files must be non-empty")
    files: dict[str, ManifestEntry] = {}
    for relative, digest in files_value.items():
        safe_relative = str(_safe_manifest_path(relative))
        if safe_relative in files:
            raise CacheVerificationError("hub snapshot manifest paths must be unique")
        files[safe_relative] = ManifestEntry(None, _validate_digest(digest))
    return SnapshotManifest(
        kind=HUB_MANIFEST_KIND,
        repository=None,
        revision=_validate_revision(payload["revision"]),
        files=files,
    )


def _load_artifact_manifest(payload: Mapping[str, Any]) -> SnapshotManifest:
    if payload["version"] != 1:
        raise CacheVerificationError("artifact snapshot manifest version must be 1")
    repository = payload["repository"]
    if (
        not isinstance(repository, str)
        or repository.count("/") != 1
        or not all(repository.split("/"))
    ):
        raise CacheVerificationError("artifact snapshot manifest repository is invalid")
    if not isinstance(payload["files"], list) or not payload["files"]:
        raise CacheVerificationError(
            "artifact snapshot manifest files must be non-empty"
        )
    files: dict[str, ManifestEntry] = {}
    for raw_file in payload["files"]:
        if not isinstance(raw_file, Mapping) or set(raw_file) != {
            "path",
            "size",
            "sha256",
        }:
            raise CacheVerificationError(
                "artifact snapshot manifest file entry is invalid"
            )
        relative = str(_safe_manifest_path(raw_file["path"]))
        size = raw_file["size"]
        if isinstance(size, bool) or not isinstance(size, int) or size < 0:
            raise CacheVerificationError(
                "artifact snapshot manifest file size is invalid"
            )
        if relative in files:
            raise CacheVerificationError(
                "artifact snapshot manifest paths must be unique"
            )
        files[relative] = ManifestEntry(size, _validate_digest(raw_file["sha256"]))
    return SnapshotManifest(
        kind=ARTIFACT_MANIFEST_KIND,
        repository=repository,
        revision=_validate_revision(payload["revision"]),
        files=files,
    )


def load_snapshot_manifest(
    manifest_path: pathlib.Path,
    expected_revision: str | None = None,
) -> SnapshotManifest:
    payload = _load_json(pathlib.Path(manifest_path))
    if not isinstance(payload, Mapping):
        raise CacheVerificationError("snapshot manifest must be a JSON object")
    fields = set(payload)
    if fields == {"files", "revision"}:
        manifest = _load_hub_manifest(payload)
    elif fields == {"version", "repository", "revision", "files"}:
        manifest = _load_artifact_manifest(payload)
    else:
        raise CacheVerificationError(
            "snapshot manifest matches neither the hub nor the artifact contract"
        )
    if expected_revision is not None and manifest.revision != expected_revision:
        raise CacheVerificationError("snapshot manifest revision does not match")
    return manifest


def _plain_directory(path: pathlib.Path, label: str) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as exc:
        raise CacheVerificationError(f"cannot access {label}: {path}") from exc
    if not stat.S_ISDIR(mode):
        raise CacheVerificationError(f"{label} must be a plain directory")


def _snapshot_files(snapshot: pathlib.Path) -> dict[str, pathlib.Path]:
    paths: dict[str, pathlib.Path] = {}
    pending = [snapshot]
    while pending:
        directory = pending.pop()
        for path in sorted(directory.iterdir(), key=lambda item: item.name):
            mode = path.lstat().st_mode
            if stat.S_ISDIR(mode):
                pending.append(path)
            elif stat.S_ISREG(mode) or stat.S_ISLNK(mode):
                paths[path.relative_to(snapshot).as_posix()] = path
            else:
                raise CacheVerificationError(
                    f"snapshot contains a non-file entry: {path}"
                )
    return paths


def _resolve_cache_file(
    path: pathlib.Path,
    repository_root: pathlib.Path,
) -> pathlib.Path:
    if not path.is_symlink():
        return path
    try:
        target = path.resolve(strict=True)
        blob_root = (repository_root / "blobs").resolve(strict=True)
        target.relative_to(blob_root)
    except (OSError, ValueError) as exc:
        raise CacheVerificationError(
            f"snapshot link target is outside the repository blob root: {path}"
        ) from exc
    if not target.is_file() or target.is_symlink():
        raise CacheVerificationError(f"snapshot blob is not a regular file: {path}")
    return target


def verify_hf_cache(
    cache_root: pathlib.Path,
    manifest_path: pathlib.Path,
) -> list[CacheFinding]:
    manifest = load_snapshot_manifest(manifest_path)
    if manifest.repository is None:
        raise CacheVerificationError(
            "cache-root verification requires the artifact manifest contract"
        )
    owner, name = manifest.repository.split("/")
    repository_root = pathlib.Path(cache_root) / f"models--{owner}--{name}"
    snapshot = repository_root / "snapshots" / manifest.revision
    _plain_directory(repository_root, "cache repository")
    _plain_directory(snapshot, "cache snapshot")
    actual = _snapshot_files(snapshot)
    expected = manifest.files
    findings: list[CacheFinding] = []

    for relative in sorted(expected):
        entry = expected[relative]
        path = actual.get(relative)
        if path is None:
            findings.append(CacheFinding(relative, "missing", "snapshot file is missing"))
            continue
        target = _resolve_cache_file(path, repository_root)
        if entry.size is not None and target.stat().st_size != entry.size:
            findings.append(
                CacheFinding(relative, "tampered", "snapshot file size does not match")
            )
            continue
        if _file_digest(target, entry.digest) != entry.digest:
            findings.append(
                CacheFinding(relative, "tampered", "snapshot file digest does not match")
            )
    for relative in sorted(set(actual) - set(expected)):
        findings.append(
            CacheFinding(relative, "unexpected", "snapshot file is not in the manifest")
        )
    return findings


def verify_snapshot(
    snapshot: pathlib.Path,
    expected_revision: str,
    expected_shards: int,
    expected_total_size: int,
    verify_blobs: bool,
    manifest_path: pathlib.Path | None = None,
) -> dict[str, int | str]:
    snapshot = pathlib.Path(snapshot)
    if snapshot.name != expected_revision:
        raise CacheVerificationError("snapshot revision path does not match")
    _plain_directory(snapshot, "cache snapshot")
    repository_root = snapshot.parent.parent
    files = _snapshot_files(snapshot)

    index_path = snapshot / "model.safetensors.index.json"
    single_path = snapshot / "model.safetensors"
    if index_path.is_file():
        index = _load_json(index_path)
        try:
            total_size = index["metadata"]["total_size"]
            weight_map = index["weight_map"]
        except (KeyError, TypeError) as exc:
            raise CacheVerificationError("safetensors index is invalid") from exc
        if (
            isinstance(total_size, bool)
            or not isinstance(total_size, int)
            or not isinstance(weight_map, Mapping)
            or not weight_map
        ):
            raise CacheVerificationError("safetensors index metadata is invalid")
        shard_names = sorted(
            relative
            for relative in files
            if pathlib.PurePosixPath(relative).match("model-*.safetensors")
        )
        mapped_shards = set(weight_map.values())
        if mapped_shards != set(shard_names):
            raise CacheVerificationError("safetensors weight map does not match shards")
    elif expected_shards == 1 and single_path.is_file():
        total_size = _resolve_cache_file(single_path, repository_root).stat().st_size
        shard_names = ["model.safetensors"]
    else:
        raise CacheVerificationError("snapshot is missing safetensors weights")

    if total_size != expected_total_size:
        raise CacheVerificationError("snapshot tensor byte count does not match")
    if len(shard_names) != expected_shards:
        raise CacheVerificationError("snapshot shard count does not match")

    manifest: SnapshotManifest | None = None
    if manifest_path is not None:
        manifest = load_snapshot_manifest(
            pathlib.Path(manifest_path),
            expected_revision,
        )
        if manifest.kind == HUB_MANIFEST_KIND and not verify_blobs:
            raise CacheVerificationError(
                "hub snapshot manifests declare no sizes and require blob verification"
            )
        missing = set(manifest.files) - set(files)
        unexpected = set(files) - set(manifest.files)
        if missing or unexpected:
            raise CacheVerificationError(
                "snapshot file set does not match the authoritative manifest"
            )

    checked: set[pathlib.Path] = set()
    size_checked = 0
    if manifest is not None:
        for relative, entry in manifest.files.items():
            path = files[relative]
            target = _resolve_cache_file(path, repository_root)
            if path.is_symlink() and target.name != entry.digest:
                raise CacheVerificationError("snapshot link names the wrong blob")
            if entry.size is not None:
                if target.stat().st_size != entry.size:
                    raise CacheVerificationError("snapshot file size does not match")
                size_checked += 1
            if verify_blobs and target not in checked:
                checked.add(target)
                if _file_digest(target, entry.digest) != entry.digest:
                    raise CacheVerificationError("snapshot blob digest does not match")
    elif verify_blobs:
        for path in files.values():
            target = _resolve_cache_file(path, repository_root)
            if target in checked:
                continue
            checked.add(target)
            if _file_digest(target, target.name) != target.name:
                raise CacheVerificationError("snapshot blob digest does not match")

    return {
        "revision": expected_revision,
        "shards": len(shard_names),
        "total_size": total_size,
        "manifest_kind": "none" if manifest is None else manifest.kind,
        "manifest_files": 0 if manifest is None else len(manifest.files),
        "size_checked_files": size_checked,
        "verified_blobs": len(checked),
    }


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="verify_hf_cache.py")
    parser.add_argument("snapshot", type=pathlib.Path)
    parser.add_argument("revision")
    parser.add_argument("shards", type=int)
    parser.add_argument("total_size", type=int)
    parser.add_argument("--verify-blobs", action="store_true")
    parser.add_argument("--manifest", required=True, type=pathlib.Path)
    return parser


def main(arguments: list[str] | None = None) -> int:
    options = _build_parser().parse_args(arguments)
    try:
        result = verify_snapshot(
            options.snapshot,
            options.revision,
            options.shards,
            options.total_size,
            options.verify_blobs,
            options.manifest,
        )
    except CacheVerificationError as exc:
        print(f"verify_hf_cache: error: {exc}", file=sys.stderr)
        return 1
    print(json.dumps(result, separators=(",", ":"), sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
