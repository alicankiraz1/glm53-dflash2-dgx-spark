#!/usr/bin/env python3
"""Check launcher option names and patch applicability against pinned source.

The default check fetches small text sources, never images or weights. Source
is parsed as AST, not imported or executed; this does not validate GPU runtime.
"""

from __future__ import annotations

import argparse
import ast
import hashlib
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parents[1]
SERVER_ARGS = "python/sglang/srt/server_args.py"
SOURCE_BASE = "https://raw.githubusercontent.com/sgl-project/sglang"
RUN_ID = "20260912T000000.000000Z-0123456789abcdef0123456789abcdef"
MAX_SOURCE_BYTES = 2 * 1024 * 1024


def registered_options(source: str) -> set[str]:
    tree = ast.parse(source)
    classes = [node for node in tree.body if isinstance(node, ast.ClassDef)
               and node.name == "ServerArgs"]
    if len(classes) != 1:
        raise ValueError("pinned source must define exactly one ServerArgs class")
    cls = classes[0]
    options: set[str] = set()
    for field in cls.body:
        if not isinstance(field, ast.AnnAssign) or not isinstance(field.target, ast.Name):
            continue
        annotation = field.annotation
        if not isinstance(annotation, ast.Subscript) or not isinstance(annotation.value, ast.Name):
            continue
        if annotation.value.id not in {"A", "Annotated"} or not isinstance(annotation.slice, ast.Tuple):
            continue
        metadata = annotation.slice.elts[1:]
        arg = next((item for item in metadata if isinstance(item, ast.Call)
                    and isinstance(item.func, ast.Name) and item.func.id == "Arg"), None)
        if arg is None and not any(isinstance(item, ast.Constant) and isinstance(item.value, str)
                                   for item in metadata):
            continue
        settings = {item.arg: item.value for item in arg.keywords} if arg else {}
        if "no_cli" in settings and ast.literal_eval(settings["no_cli"]):
            continue
        name = ast.literal_eval(settings["cli_name"]) if "cli_name" in settings else None
        options.add(name or "--" + field.target.id.replace("_", "-"))
        if "aliases" in settings:
            options.update(ast.literal_eval(settings["aliases"]) or [])
    # Manual dynamic-choice registrations live inside add_cli_args, not helpers
    # or unrelated parsers elsewhere in the module.
    for method in cls.body:
        if not isinstance(method, (ast.FunctionDef, ast.AsyncFunctionDef)) or method.name != "add_cli_args":
            continue
        for node in ast.walk(method):
            if isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute) and node.func.attr == "add_argument":
                options.update(arg.value for arg in node.args if isinstance(arg, ast.Constant)
                               and isinstance(arg.value, str) and arg.value.startswith("--"))
    return options


def generated_options(root: pathlib.Path, rank: int) -> set[str]:
    if rank not in range(4):
        raise ValueError("rank must be between 0 and 3")
    script = '''
set -eu
. ./lib/common.sh
. ./lib/config.sh
. ./lib/doctor.sh
. ./lib/lifecycle.sh
_lifecycle_load_contract tests/fixtures/cluster.valid.json config/reproduction.lock.json
_lifecycle_build_release_argv "$1" "$2"
printf '%s\\0' "${_LIFECYCLE_RELEASE_ARGV[@]}"
'''
    result = subprocess.run(["/bin/bash", "-c", script, "check", str(rank), RUN_ID],
                            cwd=root, check=True, capture_output=True, timeout=30)
    argv = result.stdout.decode().rstrip("\0").split("\0")
    try:
        start = argv.index("sglang.launch_server") + 1
    except ValueError as exc:
        raise ValueError("generated command has no SGLang entry point") from exc
    return {arg.split("=", 1)[0] for arg in argv[start:] if arg.startswith("--")}


def fetch_source(revision: str, relative: str) -> bytes:
    url = f"{SOURCE_BASE}/{revision}/{relative}"
    with urllib.request.urlopen(url, timeout=45) as response:
        data = response.read(MAX_SOURCE_BYTES + 1)
    if len(data) > MAX_SOURCE_BYTES:
        raise ValueError("upstream text source exceeds the size bound")
    return data


def verify(root: pathlib.Path) -> dict:
    lock = json.loads((root / "config/reproduction.lock.json").read_text())
    revision = lock["runtime"]["sglang_commit"]
    if len(revision) != 40 or any(char not in "0123456789abcdef" for char in revision):
        raise ValueError("SGLang revision must be a full immutable commit")
    source = fetch_source(revision, SERVER_ARGS)
    allowed = registered_options(source.decode())
    snapshot = json.loads((root / "tests/fixtures/sglang-cli.json").read_text())
    if (snapshot["revision"] != revision or snapshot["source_sha256"] != hashlib.sha256(source).hexdigest()
            or set(snapshot["options"]) != allowed):
        raise ValueError("offline CLI fixture does not match pinned upstream source")
    for rank in range(4):
        unknown = generated_options(root, rank) - allowed
        if unknown:
            raise ValueError(f"rank {rank} emits unsupported SGLang options: {sorted(unknown)}")
    series_path = root / lock["runtime"]["patch_series_path"]
    series = json.loads(series_path.read_text())
    env = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    with tempfile.TemporaryDirectory(prefix="glm53-upstream-") as directory:
        checkout = pathlib.Path(directory)
        subprocess.run(["git", "init", "--quiet", str(checkout)], check=True, env=env, timeout=15)
        for entry in series["patches"]:
            patch = series_path.parent / entry["path"]
            data = patch.read_bytes()
            if hashlib.sha256(data).hexdigest() != entry["sha256"]:
                raise ValueError("patch content differs from its series digest")
            for line in data.decode().splitlines():
                if not line.startswith("--- a/"):
                    continue
                relative = line[6:]
                path = pathlib.PurePosixPath(relative)
                if path.is_absolute() or ".." in path.parts:
                    raise ValueError("patch source path must remain inside temporary checkout")
                destination = checkout / path
                if not destination.exists():
                    destination.parent.mkdir(parents=True, exist_ok=True)
                    destination.write_bytes(fetch_source(revision, relative))
            subprocess.run(["git", "apply", "--check", str(patch)], cwd=checkout,
                           check=True, capture_output=True, env=env, timeout=30)
            subprocess.run(["git", "apply", str(patch)], cwd=checkout,
                           check=True, capture_output=True, env=env, timeout=30)
    return {"revision": revision, "ranks_checked": 4, "patches_checked": len(series["patches"]),
            "source_sha256": hashlib.sha256(source).hexdigest(), "hardware_validated": False}


def main() -> int:
    argparse.ArgumentParser(description=__doc__).parse_args()
    try:
        print(json.dumps(verify(ROOT), sort_keys=True))
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as exc:
        print(f"upstream contract: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
