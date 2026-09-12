#!/usr/bin/env python3

"""Ordered runtime patch series contract.

A series document declares the exact ordered set of patches that reproduce the
pinned runtime source tree:

    {"version": 1, "patches": [{"path": "<relative>", "sha256": "<64 hex>"}]}

Paths are interpreted relative to the directory that contains the series
document and must stay inside it. Order is significant and is never sorted,
because later patches may depend on earlier ones.
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
from typing import Any, TextIO


CHUNK_SIZE = 8 * 1024 * 1024
DIGEST_CHARACTERS = frozenset("0123456789abcdef")


class PatchSeriesError(ValueError):
    """Raised when a patch series document is malformed or unsafe."""


@dataclasses.dataclass(frozen=True)
class PatchEntry:
    path: str
    sha256: str


@dataclasses.dataclass(frozen=True)
class PatchSeries:
    version: int
    root: pathlib.Path
    patches: tuple[PatchEntry, ...]


@dataclasses.dataclass(frozen=True)
class PatchFinding:
    path: str
    code: str
    summary: str


def _load_json(path: pathlib.Path) -> Any:
    def reject_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise PatchSeriesError(f"duplicate patch series key: {key}")
            result[key] = value
        return result

    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise PatchSeriesError(f"cannot read patch series {path}: {exc}") from exc
    try:
        return json.loads(
            raw,
            object_pairs_hook=reject_duplicates,
            parse_constant=lambda value: (_ for _ in ()).throw(
                PatchSeriesError(f"non-finite patch series value: {value}")
            ),
        )
    except json.JSONDecodeError as exc:
        raise PatchSeriesError(f"patch series is not valid JSON: {exc}") from exc


def _contained_relative_path(value: Any) -> str:
    if not isinstance(value, str) or not value:
        raise PatchSeriesError("patch series path must be a non-empty string")
    path = pathlib.PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or "." in path.parts
        or str(path) != value
    ):
        raise PatchSeriesError(
            f"patch series entry must be a contained relative path: {value}"
        )
    return value


def _validate_digest(value: Any) -> str:
    if (
        not isinstance(value, str)
        or len(value) != 64
        or set(value) - DIGEST_CHARACTERS
    ):
        raise PatchSeriesError("patch series digest must be a lowercase SHA-256")
    return value


def load_patch_series(series_path: pathlib.Path) -> PatchSeries:
    path = pathlib.Path(series_path)
    payload = _load_json(path)
    if not isinstance(payload, Mapping) or set(payload) != {"version", "patches"}:
        raise PatchSeriesError("patch series must contain exactly version and patches")
    if payload["version"] != 1:
        raise PatchSeriesError("patch series version must be 1")
    raw_patches = payload["patches"]
    if not isinstance(raw_patches, list) or not raw_patches:
        raise PatchSeriesError("patch series patches must be a non-empty list")

    entries: list[PatchEntry] = []
    seen: set[str] = set()
    for raw_entry in raw_patches:
        if not isinstance(raw_entry, Mapping) or set(raw_entry) != {"path", "sha256"}:
            raise PatchSeriesError("patch series entry must contain path and sha256")
        relative = _contained_relative_path(raw_entry["path"])
        if relative in seen:
            raise PatchSeriesError(f"patch series path is duplicated: {relative}")
        seen.add(relative)
        entries.append(PatchEntry(relative, _validate_digest(raw_entry["sha256"])))

    return PatchSeries(
        version=1,
        root=path.parent,
        patches=tuple(entries),
    )


def _file_digest(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            chunk = stream.read(CHUNK_SIZE)
            if not chunk:
                return digest.hexdigest()
            digest.update(chunk)


def verify_patch_series(series_path: pathlib.Path) -> list[PatchFinding]:
    series = load_patch_series(series_path)
    findings: list[PatchFinding] = []
    for entry in series.patches:
        path = series.root.joinpath(*pathlib.PurePosixPath(entry.path).parts)
        try:
            mode = path.lstat().st_mode
        except FileNotFoundError:
            findings.append(
                PatchFinding(entry.path, "missing", "patch file is missing")
            )
            continue
        except OSError:
            findings.append(
                PatchFinding(entry.path, "unreadable", "patch file cannot be inspected")
            )
            continue
        if not stat.S_ISREG(mode):
            findings.append(
                PatchFinding(
                    entry.path,
                    "not_regular",
                    "patch file is not a plain regular file",
                )
            )
            continue
        try:
            actual = _file_digest(path)
        except OSError:
            findings.append(
                PatchFinding(entry.path, "unreadable", "patch file cannot be hashed")
            )
            continue
        if actual != entry.sha256:
            findings.append(
                PatchFinding(
                    entry.path,
                    "digest_mismatch",
                    "patch file digest does not match the series",
                )
            )
    return findings


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="patch_series.py")
    subparsers = parser.add_subparsers(dest="command", required=True)
    verify_parser = subparsers.add_parser("verify")
    verify_parser.add_argument("--series", required=True, type=pathlib.Path)
    return parser


def main(arguments: list[str] | None = None, stream: TextIO | None = None) -> int:
    options = _build_parser().parse_args(arguments)
    destination = sys.stdout if stream is None else stream
    try:
        series = load_patch_series(options.series)
        findings = verify_patch_series(options.series)
    except PatchSeriesError as exc:
        print(f"patch_series: error: {exc}", file=sys.stderr)
        return 2
    if findings:
        for finding in findings:
            print(
                f"patch_series: error: {finding.path}: {finding.summary}",
                file=sys.stderr,
            )
        return 1
    for entry in series.patches:
        destination.write(f"{entry.path}\t{entry.sha256}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
