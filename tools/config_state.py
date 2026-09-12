#!/usr/bin/env python3

from __future__ import annotations

import argparse
import dataclasses
import datetime
import hashlib
import ipaddress
import json
import os
import pathlib
import re
import stat
import sys
import tempfile
from collections.abc import Mapping
from typing import Any


STATE_VERSION = 1
RUN_ID_PATTERN = re.compile(
    r"\A[0-9]{8}T[0-9]{6}\.[0-9]{6}Z-[0-9a-f]{32}\Z"
)
IDENTIFIER_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\Z")
DIGEST_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")
STATUS_PATTERN = re.compile(r"\A[a-z][a-z0-9_-]{0,31}\Z")
EVENT_NAME_PATTERN = re.compile(r"\A[a-z][a-z0-9-]{0,31}\Z")
CONTAINER_NAME_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")
CONTAINER_ID_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")
IMAGE_REFERENCE_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._/-]*:[A-Za-z0-9][A-Za-z0-9._-]*\Z")
SAFE_ARGUMENT_PATTERN = re.compile(r"\A[A-Za-z0-9@%+=:,./_-]+\Z")
SAFE_PATH_PATTERN = re.compile(r"/[A-Za-z0-9._/-]+")
CREDENTIAL_KEY_PATTERN = re.compile(
    (
        r"(^|[_-])(api[_-]?key|auth|bearer|cert|credentials?|identity[_-]?file|"
        r"keyfile|passphrase|password|pat|private[_-]?key|secrets?|ssh[_-]?key|"
        r"token)([_-]|$)"
    ),
    re.IGNORECASE,
)


class ConfigError(ValueError):
    """Raised when cluster configuration or the reproduction lock is invalid."""


class StateError(ValueError):
    """Raised when persisted run state is invalid or unsafe."""


@dataclasses.dataclass(frozen=True)
class ClusterNode:
    id: str
    rank: int
    ssh_alias: str
    role: str
    remote_root: str
    fabric_ipv4: str
    hf_cache_root: str
    expected_machine_id_sha256: str


@dataclasses.dataclass(frozen=True)
class ClusterSSH:
    known_hosts_file: str
    fabric_known_hosts_file: str
    connect_timeout_seconds: int
    command_timeout_seconds: int


@dataclasses.dataclass(frozen=True)
class ClusterFabric:
    ipv4_cidr: str
    require_rdma: bool


@dataclasses.dataclass(frozen=True)
class ClusterPorts:
    api: int
    distributed: int


@dataclasses.dataclass(frozen=True)
class ClusterConfig:
    version: int
    ssh: ClusterSSH
    fabric: ClusterFabric
    nodes: tuple[ClusterNode, ...]
    ports: ClusterPorts


@dataclasses.dataclass(frozen=True)
class TargetModelLock:
    repository: str
    revision: str
    shards: int
    tensor_bytes: int
    hub_bytes: int
    manifest_path: str
    manifest_sha256: str


@dataclasses.dataclass(frozen=True)
class DraftModelLock:
    repository: str
    revision: str
    shards: int
    tensor_bytes: int
    manifest_path: str
    manifest_sha256: str


@dataclasses.dataclass(frozen=True)
class RuntimeLock:
    base_image: str
    arm64_digest: str
    sglang_commit: str
    image_repository: str
    image_owner: str
    containerfile_path: str
    containerfile_sha256: str
    patch_series_path: str
    patch_series_sha256: str
    tilelang_patch_sha256: str


@dataclasses.dataclass(frozen=True)
class ValidatedProfile:
    profile_name: str
    served_name: str
    tensor_parallel_size: int
    nnodes: int
    pp_size: int
    context_length: int
    max_running_requests: int
    mem_fraction_static: float
    chunked_prefill_size: int
    max_mamba_cache_size: int
    speculative_algorithm: str
    speculative_num_draft_tokens: int
    dflash_block_size: int
    draft_attention_backend: str
    prefill_attention_backend: str
    decode_attention_backend: str
    kv_cache_dtype: str
    moe_runner_backend: str
    enable_shared_experts_fusion: bool
    reasoning_parser: str
    tool_call_parser: str
    sampling_defaults: str
    radix_cache: bool
    dist_timeout_seconds: int
    api_port_default: int
    dist_port_default: int


@dataclasses.dataclass(frozen=True)
class ReproductionLock:
    version: int
    target_model: TargetModelLock
    draft_model: DraftModelLock
    runtime: RuntimeLock
    profile: ValidatedProfile


@dataclasses.dataclass(frozen=True)
class RunState:
    version: int
    run_id: str
    config_digest: str
    lock_digest: str
    created_at: str
    status: str
    data: Mapping[str, Any]


@dataclasses.dataclass(frozen=True)
class RunEvent:
    sequence: int
    recorded_at: str
    phase: str
    action: str
    status: str
    detail: Mapping[str, Any]


APPROVED_LOCK: dict[str, Any] = {
    "version": 1,
    "target_model": {
        "repository": "LibertAIDAI/GLM-5.3-Flash-NVFP4",
        "revision": "aa28e1f54130286c95fee10d0705c74ce8743734",
        "shards": 120,
        "tensor_bytes": 194644803576,
        "hub_bytes": 194692696910,
        "manifest_path": "manifests/glm53-target-aa28e1f5.json",
        "manifest_sha256": (
            "4c5abf786e4402d18980d4d4d70d682cf5b1eab69c163c785a0c2b3779ecca68"
        ),
    },
    "draft_model": {
        "repository": "incoai/GLM-5.3-Flash-DFlash2",
        "revision": "7d74cdd881ed7e32c31175984a67823127b66cfe",
        "shards": 1,
        "tensor_bytes": 2342169800,
        "manifest_path": "manifests/glm53-draft-7d74cdd8.json",
        "manifest_sha256": (
            "cf967d1b5e44ef06679add189416347782ae334c2afc1d97730de43bb71f6632"
        ),
    },
    "runtime": {
        "base_image": (
            "lmsysorg/sglang@sha256:"
            "e88340d6cd59e7356147d00de4a318f5951698c9c9dae70ba36fe12d2f034714"
        ),
        "arm64_digest": (
            "sha256:73f9294b78e38d8cc297bfed16daec8ac192b126a2d1fb9055e259a632c68f00"
        ),
        "sglang_commit": "92831e5ec1e109b1be6d7071281557cd6481f4f5",
        "image_repository": "glm53-dflash2-dgx-spark",
        "image_owner": "glm53-spark",
        "containerfile_path": "runtime/Containerfile",
        "containerfile_sha256": (
            "5c8af452ee1495b19843b2676207373fb450f074d63e22666229f5ee1002fd6d"
        ),
        "patch_series_path": "runtime/patches/series.json",
        "patch_series_sha256": (
            "7f91ea0f6cf72c5732ed7be7295e1ac8e60e35d072dc54feac51a56e5af3b898"
        ),
        "tilelang_patch_sha256": (
            "9399746b546825af723d4fcad88373e77891a49c0b2c356d37841b381b5b85e3"
        ),
    },
    "profile": {
        "profile_name": "dflash-c4-128k-noradix",
        "served_name": "glm-5.3-flash-nvfp4",
        "tensor_parallel_size": 4,
        "nnodes": 4,
        "pp_size": 1,
        "context_length": 131072,
        "max_running_requests": 4,
        "mem_fraction_static": 0.85,
        "chunked_prefill_size": 8192,
        "max_mamba_cache_size": 20,
        "speculative_algorithm": "DFLASH",
        "speculative_num_draft_tokens": 8,
        "dflash_block_size": 8,
        "draft_attention_backend": "fa4",
        "prefill_attention_backend": "tilelang",
        "decode_attention_backend": "tilelang",
        "kv_cache_dtype": "bfloat16",
        "moe_runner_backend": "flashinfer_cutlass",
        "enable_shared_experts_fusion": False,
        "reasoning_parser": "glm45",
        "tool_call_parser": "glm47",
        "sampling_defaults": "model",
        "radix_cache": False,
        "dist_timeout_seconds": 3600,
        "api_port_default": 8002,
        "dist_port_default": 29600,
    },
}


def _read_json(path: pathlib.Path, error_type: type[ValueError]) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise error_type(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def reject_non_finite(value: str) -> None:
        raise error_type(f"non-finite JSON number is not allowed: {value}")

    try:
        raw = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise error_type(f"cannot read {path}: {exc}") from exc
    try:
        return json.loads(
            raw,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_non_finite,
        )
    except json.JSONDecodeError as exc:
        raise error_type(f"{path} is not valid JSON: {exc}") from exc


def _reject_credential_keys(value: Any, error_type: type[ValueError]) -> None:
    if isinstance(value, Mapping):
        for key, child in value.items():
            if CREDENTIAL_KEY_PATTERN.search(str(key)):
                raise error_type(f"embedded credential key is forbidden: {key}")
            _reject_credential_keys(child, error_type)
    elif isinstance(value, list):
        for child in value:
            _reject_credential_keys(child, error_type)


def _require_object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ConfigError(f"{location} must be a JSON object")
    return value


def _require_exact_keys(
    value: Mapping[str, Any],
    expected: set[str],
    location: str,
) -> None:
    actual = set(value)
    unknown = sorted(actual - expected)
    missing = sorted(expected - actual)
    if unknown:
        raise ConfigError(f"{location} contains unknown keys: {', '.join(unknown)}")
    if missing:
        raise ConfigError(f"{location} is missing keys: {', '.join(missing)}")


def _require_string(value: Any, location: str) -> str:
    if not isinstance(value, str) or not value:
        raise ConfigError(f"{location} must be a non-empty string")
    return value


def _require_integer(value: Any, location: str) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise ConfigError(f"{location} must be an integer")
    return value


def _require_boolean(value: Any, location: str) -> bool:
    if not isinstance(value, bool):
        raise ConfigError(f"{location} must be a boolean")
    return value


def _validate_identifier(value: Any, location: str) -> str:
    identifier = _require_string(value, location)
    if not IDENTIFIER_PATTERN.fullmatch(identifier) or identifier in {".", ".."}:
        raise ConfigError(f"{location} must be a safe logical identifier")
    return identifier


def _validate_port(value: Any, location: str) -> int:
    port = _require_integer(value, location)
    if port < 1 or port > 65535:
        raise ConfigError(f"{location} must be between 1 and 65535")
    return port


def _validate_known_hosts_file(value: Any, location: str) -> str:
    path = _require_string(value, location)
    contains_control = any(
        ord(character) < 32 or ord(character) == 127 for character in path
    )
    if not path.strip() or contains_control:
        raise ConfigError(f"{location} must not be blank or contain control characters")
    return path


def _validate_absolute_posix_path(value: Any, location: str) -> str:
    path_text = _require_string(value, location)
    path = pathlib.PurePosixPath(path_text)
    if (
        not path.is_absolute()
        or path_text == "/"
        or ".." in path.parts
        or str(path) != path_text
    ):
        raise ConfigError(f"{location} must be a normalized absolute POSIX path")
    return path_text


def _validate_safe_absolute_posix_path(value: Any, location: str) -> str:
    """Reject paths that could be reinterpreted by a shell, ssh, or rsync."""
    path_text = _validate_absolute_posix_path(value, location)
    if SAFE_PATH_PATTERN.fullmatch(path_text) is None:
        raise ConfigError(f"{location} must be a safe absolute POSIX path")
    return path_text


def _validate_timeout(
    value: Any,
    location: str,
    maximum: int,
) -> int:
    timeout = _require_integer(value, location)
    if timeout < 1 or timeout > maximum:
        raise ConfigError(f"{location} must be between 1 and {maximum}")
    return timeout


def _validate_ipv4_cidr(value: Any, location: str) -> str:
    cidr = _require_string(value, location)
    try:
        network = ipaddress.ip_network(cidr, strict=True)
    except ValueError as exc:
        raise ConfigError(f"{location} must be a canonical IPv4 CIDR") from exc
    if not isinstance(network, ipaddress.IPv4Network):
        raise ConfigError(f"{location} must be a canonical IPv4 CIDR")
    return str(network)


def _validate_ipv4_address(value: Any, location: str) -> str:
    address_text = _require_string(value, location)
    try:
        address = ipaddress.ip_address(address_text)
    except ValueError as exc:
        raise ConfigError(f"{location} must be a canonical IPv4 address") from exc
    if not isinstance(address, ipaddress.IPv4Address) or str(address) != address_text:
        raise ConfigError(f"{location} must be a canonical IPv4 address")
    return str(address)


def _validate_digest(value: Any, location: str) -> str:
    digest = _require_string(value, location)
    if not DIGEST_PATTERN.fullmatch(digest):
        raise ConfigError(f"{location} must be a lowercase SHA-256 digest")
    return digest


def load_cluster(path: pathlib.Path) -> ClusterConfig:
    value = _read_json(pathlib.Path(path), ConfigError)
    _reject_credential_keys(value, ConfigError)
    root = _require_object(value, "cluster")
    _require_exact_keys(
        root,
        {"version", "ssh", "fabric", "nodes", "ports"},
        "cluster",
    )

    version = _require_integer(root["version"], "cluster.version")
    if version != 1:
        raise ConfigError("cluster.version must be 1")

    raw_ssh = _require_object(root["ssh"], "cluster.ssh")
    _require_exact_keys(
        raw_ssh,
        {
            "known_hosts_file",
            "fabric_known_hosts_file",
            "connect_timeout_seconds",
            "command_timeout_seconds",
        },
        "cluster.ssh",
    )
    ssh = ClusterSSH(
        known_hosts_file=_validate_known_hosts_file(
            raw_ssh["known_hosts_file"],
            "cluster.ssh.known_hosts_file",
        ),
        fabric_known_hosts_file=_validate_safe_absolute_posix_path(
            raw_ssh["fabric_known_hosts_file"],
            "cluster.ssh.fabric_known_hosts_file",
        ),
        connect_timeout_seconds=_validate_timeout(
            raw_ssh["connect_timeout_seconds"],
            "cluster.ssh.connect_timeout_seconds",
            600,
        ),
        command_timeout_seconds=_validate_timeout(
            raw_ssh["command_timeout_seconds"],
            "cluster.ssh.command_timeout_seconds",
            3600,
        ),
    )

    raw_fabric = _require_object(root["fabric"], "cluster.fabric")
    _require_exact_keys(
        raw_fabric,
        {"ipv4_cidr", "require_rdma"},
        "cluster.fabric",
    )
    require_rdma = _require_boolean(
        raw_fabric["require_rdma"],
        "cluster.fabric.require_rdma",
    )
    if not require_rdma:
        raise ConfigError("cluster.fabric.require_rdma must be true")
    fabric = ClusterFabric(
        ipv4_cidr=_validate_ipv4_cidr(
            raw_fabric["ipv4_cidr"],
            "cluster.fabric.ipv4_cidr",
        ),
        require_rdma=require_rdma,
    )

    raw_nodes = root["nodes"]
    if not isinstance(raw_nodes, list) or len(raw_nodes) != 4:
        raise ConfigError("cluster.nodes must contain exactly four ordered nodes")

    nodes: list[ClusterNode] = []
    for index, raw_node in enumerate(raw_nodes):
        location = f"cluster.nodes[{index}]"
        node = _require_object(raw_node, location)
        _require_exact_keys(
            node,
            {
                "id",
                "rank",
                "ssh_alias",
                "role",
                "remote_root",
                "fabric_ipv4",
                "hf_cache_root",
                "expected_machine_id_sha256",
            },
            location,
        )
        role = _require_string(node["role"], f"{location}.role")
        if role not in {"source", "worker"}:
            raise ConfigError(f"{location}.role must be source or worker")
        nodes.append(
            ClusterNode(
                id=_validate_identifier(node["id"], f"{location}.id"),
                rank=_require_integer(node["rank"], f"{location}.rank"),
                ssh_alias=_validate_identifier(
                    node["ssh_alias"],
                    f"{location}.ssh_alias",
                ),
                role=role,
                remote_root=_validate_safe_absolute_posix_path(
                    node["remote_root"],
                    f"{location}.remote_root",
                ),
                fabric_ipv4=_validate_ipv4_address(
                    node["fabric_ipv4"],
                    f"{location}.fabric_ipv4",
                ),
                hf_cache_root=_validate_safe_absolute_posix_path(
                    node["hf_cache_root"],
                    f"{location}.hf_cache_root",
                ),
                expected_machine_id_sha256=_validate_digest(
                    node["expected_machine_id_sha256"],
                    f"{location}.expected_machine_id_sha256",
                ),
            )
        )

    ranks = [node.rank for node in nodes]
    if ranks != [0, 1, 2, 3]:
        raise ConfigError("cluster node ranks must be unique and ordered 0, 1, 2, 3")
    logical_ids = [node.id for node in nodes]
    if len(set(logical_ids)) != 4:
        raise ConfigError("cluster node logical IDs must be unique")
    aliases = [node.ssh_alias for node in nodes]
    if len(set(aliases)) != 4:
        raise ConfigError("cluster node SSH aliases must be unique")
    if [node.role for node in nodes].count("source") != 1:
        raise ConfigError("cluster must designate exactly one source node")
    fabric_addresses = [node.fabric_ipv4 for node in nodes]
    if len(set(fabric_addresses)) != 4:
        raise ConfigError("cluster node fabric addresses must be unique")
    fabric_network = ipaddress.ip_network(fabric.ipv4_cidr)
    if any(ipaddress.ip_address(address) not in fabric_network for address in fabric_addresses):
        raise ConfigError("cluster node fabric addresses must belong to the fabric CIDR")

    raw_ports = _require_object(root["ports"], "cluster.ports")
    _require_exact_keys(raw_ports, {"api", "distributed"}, "cluster.ports")
    ports = ClusterPorts(
        api=_validate_port(raw_ports["api"], "cluster.ports.api"),
        distributed=_validate_port(
            raw_ports["distributed"],
            "cluster.ports.distributed",
        ),
    )
    if ports.api == ports.distributed:
        raise ConfigError("cluster API and distributed ports must be distinct")

    return ClusterConfig(
        version=version,
        ssh=ssh,
        fabric=fabric,
        nodes=tuple(nodes),
        ports=ports,
    )


def _first_difference(actual: Any, expected: Any, location: str = "lock") -> str:
    if type(actual) is not type(expected):
        return location
    if isinstance(expected, dict):
        if set(actual) != set(expected):
            return location
        for key in expected:
            difference = _first_difference(
                actual[key],
                expected[key],
                f"{location}.{key}",
            )
            if difference:
                return difference
        return ""
    if actual != expected:
        return location
    return ""


def load_reproduction_lock(path: pathlib.Path) -> ReproductionLock:
    value = _read_json(pathlib.Path(path), ConfigError)
    _reject_credential_keys(value, ConfigError)
    difference = _first_difference(value, APPROVED_LOCK)
    if difference:
        raise ConfigError(
            f"{difference} differs from the approved reproduction lock"
        )

    return ReproductionLock(
        version=value["version"],
        target_model=TargetModelLock(**value["target_model"]),
        draft_model=DraftModelLock(**value["draft_model"]),
        runtime=RuntimeLock(**value["runtime"]),
        profile=ValidatedProfile(**value["profile"]),
    )


def _canonical_bytes(value: Any) -> bytes:
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as exc:
        raise StateError(f"value is not canonical JSON data: {exc}") from exc
    return encoded.encode("utf-8")


def config_digest(cluster: ClusterConfig) -> str:
    if not isinstance(cluster, ClusterConfig):
        raise ConfigError("config_digest requires a validated ClusterConfig")
    return hashlib.sha256(_canonical_bytes(dataclasses.asdict(cluster))).hexdigest()


def lock_digest(lock: ReproductionLock) -> str:
    if not isinstance(lock, ReproductionLock):
        raise ConfigError("lock_digest requires a validated ReproductionLock")
    return hashlib.sha256(_canonical_bytes(dataclasses.asdict(lock))).hexdigest()


def new_run_id(now: datetime.datetime, entropy: bytes) -> str:
    if not isinstance(now, datetime.datetime) or now.tzinfo is None:
        raise StateError("run ID timestamp must be timezone-aware")
    if not isinstance(entropy, bytes) or len(entropy) < 16:
        raise StateError("run ID entropy must contain at least 16 bytes")
    timestamp = now.astimezone(datetime.timezone.utc)
    timestamp_text = timestamp.strftime("%Y%m%dT%H%M%S.%fZ")
    return f"{timestamp_text}-{entropy[:16].hex()}"


def _validate_run_id(run_id: Any) -> str:
    if not isinstance(run_id, str) or not RUN_ID_PATTERN.fullmatch(run_id):
        raise StateError("run ID is malformed or path-unsafe")
    return run_id


def _validate_created_at(created_at: Any) -> str:
    if not isinstance(created_at, str) or not created_at.endswith("Z"):
        raise StateError("state created_at must be a UTC ISO-8601 timestamp")
    try:
        parsed = datetime.datetime.fromisoformat(created_at[:-1] + "+00:00")
    except ValueError as exc:
        raise StateError("state created_at must be a valid timestamp") from exc
    if parsed.tzinfo != datetime.timezone.utc:
        raise StateError("state created_at must use UTC")
    return created_at


def _validate_run_state(state: RunState) -> None:
    if not isinstance(state, RunState):
        raise StateError("state must be a RunState")
    if state.version != STATE_VERSION:
        raise StateError(f"state version must be {STATE_VERSION}")
    _validate_run_id(state.run_id)
    for name, digest in (
        ("config_digest", state.config_digest),
        ("lock_digest", state.lock_digest),
    ):
        if not isinstance(digest, str) or not DIGEST_PATTERN.fullmatch(digest):
            raise StateError(f"state {name} must be a lowercase SHA-256 digest")
    _validate_created_at(state.created_at)
    if not isinstance(state.status, str) or not STATUS_PATTERN.fullmatch(state.status):
        raise StateError("state status is malformed")
    if not isinstance(state.data, Mapping):
        raise StateError("state data must be a JSON object")
    _reject_credential_keys(state.data, StateError)
    _canonical_bytes(state.data)


def _state_payload(state: RunState) -> dict[str, Any]:
    return {
        "version": state.version,
        "run_id": state.run_id,
        "config_digest": state.config_digest,
        "lock_digest": state.lock_digest,
        "created_at": state.created_at,
        "status": state.status,
        "data": dict(state.data),
    }


def _record_digest(payload: Mapping[str, Any]) -> str:
    return hashlib.sha256(_canonical_bytes(payload)).hexdigest()


def _ensure_private_directory(path: pathlib.Path) -> None:
    if path.exists():
        if path.is_symlink() or not path.is_dir():
            raise StateError(f"state path is not a plain directory: {path}")
    else:
        try:
            path.mkdir(mode=0o700)
        except OSError as exc:
            raise StateError(f"cannot create state directory {path}: {exc}") from exc
    try:
        path.chmod(0o700)
    except OSError as exc:
        raise StateError(f"cannot secure state directory {path}: {exc}") from exc


def _require_plain_directory(path: pathlib.Path) -> None:
    try:
        mode = path.lstat().st_mode
    except OSError as exc:
        raise StateError(f"cannot access state directory {path}: {exc}") from exc
    if not stat.S_ISDIR(mode):
        raise StateError(f"state path is not a plain directory: {path}")


def write_run_state(state_root: pathlib.Path, state: RunState) -> pathlib.Path:
    _validate_run_state(state)
    root = pathlib.Path(state_root)
    try:
        root.mkdir(mode=0o700, parents=True, exist_ok=True)
    except OSError as exc:
        raise StateError(f"cannot create state root {root}: {exc}") from exc
    _ensure_private_directory(root)
    runs_directory = root / "runs"
    _ensure_private_directory(runs_directory)
    run_directory = runs_directory / state.run_id
    _ensure_private_directory(run_directory)
    destination = run_directory / "run.json"

    payload = _state_payload(state)
    record = dict(payload)
    record["record_digest"] = _record_digest(payload)
    encoded = _canonical_bytes(record) + b"\n"
    temporary_path: pathlib.Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="wb",
            dir=run_directory,
            prefix=".run.json.",
            delete=False,
        ) as temporary_file:
            temporary_path = pathlib.Path(temporary_file.name)
            os.fchmod(temporary_file.fileno(), 0o600)
            temporary_file.write(encoded)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.replace(temporary_path, destination)
        temporary_path = None
        os.chmod(destination, 0o600)
        directory_descriptor = os.open(run_directory, os.O_RDONLY)
        try:
            os.fsync(directory_descriptor)
        finally:
            os.close(directory_descriptor)
    except OSError as exc:
        raise StateError(f"cannot atomically write state {destination}: {exc}") from exc
    finally:
        if temporary_path is not None:
            try:
                temporary_path.unlink()
            except FileNotFoundError:
                pass
    return destination


def read_run_state(state_root: pathlib.Path, run_id: str) -> RunState:
    validated_run_id = _validate_run_id(run_id)
    root = pathlib.Path(state_root)
    runs_directory = root / "runs"
    run_directory = runs_directory / validated_run_id
    _require_plain_directory(root)
    _require_plain_directory(runs_directory)
    _require_plain_directory(run_directory)
    state_path = run_directory / "run.json"
    try:
        mode = state_path.lstat().st_mode
    except OSError as exc:
        raise StateError(f"cannot access run state {state_path}: {exc}") from exc
    if not stat.S_ISREG(mode):
        raise StateError(f"run state is not a plain file: {state_path}")

    value = _read_json(state_path, StateError)
    if not isinstance(value, dict):
        raise StateError("run state must be a JSON object")
    expected_keys = {
        "version",
        "run_id",
        "config_digest",
        "lock_digest",
        "created_at",
        "status",
        "data",
        "record_digest",
    }
    if set(value) != expected_keys:
        raise StateError("run state contains missing or unknown fields")
    record_digest_value = value.pop("record_digest")
    if (
        not isinstance(record_digest_value, str)
        or not DIGEST_PATTERN.fullmatch(record_digest_value)
        or _record_digest(value) != record_digest_value
    ):
        raise StateError("run state record digest does not match its contents")

    state = RunState(
        version=value["version"],
        run_id=value["run_id"],
        config_digest=value["config_digest"],
        lock_digest=value["lock_digest"],
        created_at=value["created_at"],
        status=value["status"],
        data=value["data"],
    )
    _validate_run_state(state)
    if state.run_id != validated_run_id:
        raise StateError("run state run ID does not match its path")
    return state


def _validate_run_event(event: RunEvent) -> None:
    if not isinstance(event, RunEvent):
        raise StateError("event must be a RunEvent")
    if isinstance(event.sequence, bool) or not isinstance(event.sequence, int):
        raise StateError("event sequence must be an integer")
    if event.sequence < 1:
        raise StateError("event sequence must start at one")
    _validate_created_at(event.recorded_at)
    for name, value in (("phase", event.phase), ("action", event.action)):
        if not isinstance(value, str) or not EVENT_NAME_PATTERN.fullmatch(value):
            raise StateError(f"event {name} is malformed")
    if not isinstance(event.status, str) or not STATUS_PATTERN.fullmatch(event.status):
        raise StateError("event status is malformed")
    if not isinstance(event.detail, Mapping):
        raise StateError("event detail must be a JSON object")
    _reject_credential_keys(event.detail, StateError)
    _canonical_bytes(event.detail)


def _event_payload(event: RunEvent) -> dict[str, Any]:
    return {
        "version": STATE_VERSION,
        "sequence": event.sequence,
        "recorded_at": event.recorded_at,
        "phase": event.phase,
        "action": event.action,
        "status": event.status,
        "detail": dict(event.detail),
    }


def _recorded_run_directory(
    state_root: pathlib.Path,
    run_id: str,
) -> pathlib.Path:
    validated_run_id = _validate_run_id(run_id)
    root = pathlib.Path(state_root)
    runs_directory = root / "runs"
    run_directory = runs_directory / validated_run_id
    _require_plain_directory(root)
    _require_plain_directory(runs_directory)
    _require_plain_directory(run_directory)
    state_path = run_directory / "run.json"
    try:
        mode = state_path.lstat().st_mode
    except OSError as exc:
        raise StateError(f"run state is not recorded yet: {state_path}") from exc
    if not stat.S_ISREG(mode):
        raise StateError(f"run state is not a plain file: {state_path}")
    return run_directory


def _events_path(run_directory: pathlib.Path) -> pathlib.Path:
    return run_directory / "events.jsonl"


def _parse_run_events(path: pathlib.Path) -> tuple[RunEvent, ...]:
    try:
        raw = path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ()
    except OSError as exc:
        raise StateError(f"cannot read run events {path}: {exc}") from exc

    events: list[RunEvent] = []
    for index, line in enumerate(raw.splitlines(), start=1):
        if not line:
            raise StateError(f"run event line {index} is empty")
        try:
            value = json.loads(line)
        except json.JSONDecodeError as exc:
            raise StateError(f"run event line {index} is not valid JSON: {exc}") from exc
        if not isinstance(value, dict):
            raise StateError(f"run event line {index} must be a JSON object")
        expected_keys = {
            "version",
            "sequence",
            "recorded_at",
            "phase",
            "action",
            "status",
            "detail",
        }
        if set(value) != expected_keys:
            raise StateError(f"run event line {index} has missing or unknown fields")
        if value["version"] != STATE_VERSION:
            raise StateError(f"run event line {index} has an unsupported version")
        event = RunEvent(
            sequence=value["sequence"],
            recorded_at=value["recorded_at"],
            phase=value["phase"],
            action=value["action"],
            status=value["status"],
            detail=value["detail"],
        )
        _validate_run_event(event)
        if event.sequence != index:
            raise StateError(f"run event line {index} has a non-monotonic sequence")
        events.append(event)
    return tuple(events)


def append_run_event(
    state_root: pathlib.Path,
    run_id: str,
    event: RunEvent,
) -> None:
    _validate_run_id(run_id)
    _validate_run_event(event)
    run_directory = _recorded_run_directory(state_root, run_id)
    destination = _events_path(run_directory)
    existing = _parse_run_events(destination)
    if event.sequence != len(existing) + 1:
        raise StateError(
            "run event sequence must continue the append-only log by exactly one"
        )

    line = _canonical_bytes(_event_payload(event)) + b"\n"
    try:
        descriptor = os.open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
            0o600,
        )
    except OSError as exc:
        raise StateError(f"cannot open run events {destination}: {exc}") from exc
    try:
        os.fchmod(descriptor, 0o600)
        written = os.write(descriptor, line)
        if written != len(line):
            raise StateError(f"run event append was truncated: {destination}")
        os.fsync(descriptor)
    except OSError as exc:
        raise StateError(f"cannot append run event {destination}: {exc}") from exc
    finally:
        os.close(descriptor)


def read_run_events(
    state_root: pathlib.Path,
    run_id: str,
) -> tuple[RunEvent, ...]:
    run_directory = _recorded_run_directory(state_root, run_id)
    return _parse_run_events(_events_path(run_directory))


def _export_cluster_field(cluster: ClusterConfig, field: str) -> str:
    source_node = next(node for node in cluster.nodes if node.role == "source")
    fixed_fields: dict[str, str] = {
        "version": str(cluster.version),
        "node_count": str(len(cluster.nodes)),
        "source_node_id": source_node.id,
        "source_ssh_alias": source_node.ssh_alias,
        "source_remote_root": source_node.remote_root,
        "source_hf_cache_root": source_node.hf_cache_root,
        "ssh_known_hosts_file": cluster.ssh.known_hosts_file,
        "ssh_fabric_known_hosts_file": cluster.ssh.fabric_known_hosts_file,
        "ssh_connect_timeout_seconds": str(cluster.ssh.connect_timeout_seconds),
        "ssh_command_timeout_seconds": str(cluster.ssh.command_timeout_seconds),
        "fabric_ipv4_cidr": cluster.fabric.ipv4_cidr,
        "fabric_require_rdma": str(cluster.fabric.require_rdma).lower(),
        "api_port": str(cluster.ports.api),
        "dist_port": str(cluster.ports.distributed),
        "config_digest": config_digest(cluster),
    }
    if field in fixed_fields:
        return fixed_fields[field]

    match = re.fullmatch(
        (
            r"node\.([0-3])\."
            r"(id|rank|ssh_alias|role|remote_root|fabric_ipv4|hf_cache_root|"
            r"expected_machine_id_sha256)"
        ),
        field,
    )
    if match is None:
        raise ConfigError(f"unsupported config export field: {field}")
    node = cluster.nodes[int(match.group(1))]
    return str(getattr(node, match.group(2)))


def _export_doctor_fields(cluster: ClusterConfig) -> None:
    values = [
        cluster.ssh.known_hosts_file,
        str(cluster.ssh.connect_timeout_seconds),
        str(cluster.ssh.command_timeout_seconds),
        cluster.fabric.ipv4_cidr,
        str(cluster.ports.api),
        str(cluster.ports.distributed),
    ]
    for node in cluster.nodes:
        values.extend((node.id, node.ssh_alias, node.role, node.remote_root))
    for value in values:
        sys.stdout.buffer.write(value.encode("utf-8") + b"\0")


def _export_prepare_fields(
    cluster: ClusterConfig,
    lock: ReproductionLock,
) -> None:
    source = next(node for node in cluster.nodes if node.role == "source")
    values = [
        config_digest(cluster),
        lock_digest(lock),
        source.id,
        source.ssh_alias,
        source.remote_root,
        source.hf_cache_root,
        cluster.ssh.fabric_known_hosts_file,
        str(cluster.ssh.connect_timeout_seconds),
        str(cluster.ssh.command_timeout_seconds),
        lock.target_model.repository,
        lock.target_model.revision,
        str(lock.target_model.shards),
        str(lock.target_model.tensor_bytes),
        str(lock.target_model.hub_bytes),
        lock.target_model.manifest_path,
        lock.target_model.manifest_sha256,
        lock.draft_model.repository,
        lock.draft_model.revision,
        str(lock.draft_model.shards),
        str(lock.draft_model.tensor_bytes),
        lock.draft_model.manifest_path,
        lock.draft_model.manifest_sha256,
        lock.runtime.base_image,
        lock.runtime.arm64_digest,
        lock.runtime.sglang_commit,
        lock.runtime.image_repository,
        lock.runtime.image_owner,
        lock.runtime.containerfile_path,
        lock.runtime.containerfile_sha256,
        lock.runtime.patch_series_path,
        lock.runtime.patch_series_sha256,
        lock.runtime.tilelang_patch_sha256,
    ]
    for node in cluster.nodes:
        values.extend(
            (
                node.id,
                node.ssh_alias,
                node.role,
                node.remote_root,
                node.fabric_ipv4,
                node.hf_cache_root,
                node.expected_machine_id_sha256,
            )
        )
    for value in values:
        sys.stdout.buffer.write(value.encode("utf-8") + b"\0")


def _export_lifecycle_fields(
    cluster: ClusterConfig,
    lock: ReproductionLock,
) -> None:
    profile = lock.profile
    values = [
        config_digest(cluster),
        lock_digest(lock),
        cluster.ssh.known_hosts_file,
        str(cluster.ssh.connect_timeout_seconds),
        str(cluster.ssh.command_timeout_seconds),
        str(cluster.ports.api),
        str(cluster.ports.distributed),
        lock.runtime.image_repository,
        lock.runtime.image_owner,
        lock.target_model.repository,
        lock.target_model.revision,
        lock.target_model.manifest_path,
        lock.target_model.manifest_sha256,
        lock.draft_model.repository,
        lock.draft_model.revision,
        lock.draft_model.manifest_path,
        lock.draft_model.manifest_sha256,
        lock.runtime.containerfile_path,
        lock.runtime.containerfile_sha256,
        lock.runtime.patch_series_path,
        lock.runtime.patch_series_sha256,
        lock.runtime.tilelang_patch_sha256,
        profile.profile_name,
        profile.served_name,
        str(profile.tensor_parallel_size),
        str(profile.nnodes),
        str(profile.pp_size),
        str(profile.context_length),
        str(profile.max_running_requests),
        str(profile.mem_fraction_static),
        str(profile.chunked_prefill_size),
        str(profile.max_mamba_cache_size),
        profile.speculative_algorithm,
        str(profile.speculative_num_draft_tokens),
        str(profile.dflash_block_size),
        profile.draft_attention_backend,
        profile.prefill_attention_backend,
        profile.decode_attention_backend,
        profile.kv_cache_dtype,
        profile.moe_runner_backend,
        str(profile.enable_shared_experts_fusion).lower(),
        profile.reasoning_parser,
        profile.tool_call_parser,
        profile.sampling_defaults,
        str(profile.radix_cache).lower(),
        str(profile.dist_timeout_seconds),
    ]
    for node in cluster.nodes:
        values.extend(
            (
                node.id,
                str(node.rank),
                node.ssh_alias,
                node.role,
                node.remote_root,
                node.fabric_ipv4,
                node.hf_cache_root,
                node.expected_machine_id_sha256,
            )
        )
    for value in values:
        sys.stdout.buffer.write(value.encode("utf-8") + b"\0")


def _require_safe_argument(value: str, location: str) -> str:
    if not isinstance(value, str) or not SAFE_ARGUMENT_PATTERN.fullmatch(value):
        raise StateError(f"{location} is not a shell-safe value")
    return value


def _require_container_name(value: str, location: str) -> str:
    if not isinstance(value, str) or not CONTAINER_NAME_PATTERN.fullmatch(value):
        raise StateError(f"{location} is not a safe container name")
    return value


def _require_container_id(value: Any, location: str) -> str:
    if not isinstance(value, str) or not CONTAINER_ID_PATTERN.fullmatch(value):
        raise StateError(f"{location} is not a full 64-character container ID")
    return value


def _require_state_ipv4(value: Any, location: str) -> str:
    try:
        address = ipaddress.IPv4Address(str(value))
    except ipaddress.AddressValueError as exc:
        raise StateError(f"{location} is not a canonical IPv4 address") from exc
    if str(address) != str(value):
        raise StateError(f"{location} is not a canonical IPv4 address")
    return str(address)


def _require_state_path(value: str, location: str) -> str:
    path = pathlib.PurePosixPath(str(value))
    if (
        not path.is_absolute()
        or str(path) != str(value)
        or ".." in path.parts
        or SAFE_PATH_PATTERN.fullmatch(str(value)) is None
    ):
        raise StateError(f"{location} is not a safe absolute POSIX path")
    return str(value)


def _split_record(line: str, expected_fields: int) -> list[str]:
    fields = line.split("\t")
    if len(fields) != expected_fields:
        raise StateError(f"run record has {len(fields)} fields, expected {expected_fields}")
    return fields


def _require_rank(value: str) -> int:
    if value not in {"0", "1", "2", "3"}:
        raise StateError("run record rank must be 0, 1, 2, or 3")
    return int(value)


def _parse_launch_records(text: str) -> list[dict[str, Any]]:
    """Parse the controller's tab-delimited launch record stream."""
    ranks: dict[int, dict[str, Any]] = {}
    for line in text.splitlines():
        if not line:
            continue
        kind = line.split("\t", 1)[0]
        if kind == "rank":
            fields = _split_record(line, 8)
            rank = _require_rank(fields[1])
            if rank in ranks:
                raise StateError(f"run record repeats rank {rank}")
            ranks[rank] = {
                "rank": rank,
                "node_id": _validate_identifier(fields[2], "run record node_id"),
                "ssh_alias": _validate_identifier(fields[3], "run record ssh_alias"),
                "fabric_ipv4": _require_state_ipv4(
                    fields[4],
                    "run record fabric_ipv4",
                ),
                "remote_root": _require_state_path(fields[5], "run record remote_root"),
                "hf_cache_root": _require_state_path(
                    fields[6],
                    "run record hf_cache_root",
                ),
                "container_name": _require_container_name(
                    fields[7],
                    "run record container_name",
                ),
                # Docker assigns this immutable identity only after the rank
                # is released. It is filled by record-rank-container-id
                # before any later lifecycle mutation can address the rank.
                "container_id": "",
                "argv": [],
                "mounts": [],
                "prelaunch_services": [],
                "rollback_actions": [],
            }
        elif kind == "argv":
            fields = _split_record(line, 3)
            rank_record = ranks[_require_rank(fields[1])]
            rank_record["argv"].append(
                _require_safe_argument(fields[2], "run record argv value"),
            )
        elif kind == "mount":
            fields = _split_record(line, 5)
            rank_record = ranks[_require_rank(fields[1])]
            if fields[4] not in {"ro", "rw"}:
                raise StateError("run record mount mode must be ro or rw")
            rank_record["mounts"].append(
                {
                    "source": _require_state_path(fields[2], "run record mount source"),
                    "target": _require_state_path(fields[3], "run record mount target"),
                    "mode": fields[4],
                }
            )
        elif kind == "service":
            fields = _split_record(line, 6)
            rank_record = ranks[_require_rank(fields[1])]
            container_id = _require_container_id(
                fields[2],
                "run record service container_id",
            )
            name = _require_container_name(fields[3], "run record service name")
            state = _validate_identifier(fields[5], "run record service state")
            rank_record["prelaunch_services"].append(
                {
                    "container_id": container_id,
                    "name": name,
                    "image": _require_safe_argument(
                        fields[4],
                        "run record service image",
                    ),
                    "state": state,
                }
            )
            if state == "running":
                rank_record["rollback_actions"].append(
                    {
                        "action": "docker-start",
                        "container_id": container_id,
                        "container": name,
                    }
                )
        else:
            raise StateError(f"unsupported run record kind: {kind}")

    if set(ranks) != {0, 1, 2, 3}:
        raise StateError("run record must describe exactly ranks 0, 1, 2, and 3")
    for rank, rank_record in ranks.items():
        if not rank_record["argv"]:
            raise StateError(f"run record rank {rank} has no launch arguments")
        if not rank_record["mounts"]:
            raise StateError(f"run record rank {rank} has no mounts")
    return [ranks[rank] for rank in sorted(ranks)]


def _build_run_data(
    owner: str,
    profile_name: str,
    image_reference: str,
    served_model_name: str,
    model_path: str,
    api_port: int,
    dist_port: int,
    ranks: list[dict[str, Any]],
) -> dict[str, Any]:
    if not IMAGE_REFERENCE_PATTERN.fullmatch(image_reference):
        raise StateError("run image reference is malformed")
    return {
        "owner": _validate_identifier(owner, "run owner"),
        "profile_name": _validate_identifier(profile_name, "run profile_name"),
        "image_reference": image_reference,
        "served_model_name": _validate_identifier(
            served_model_name,
            "run served_model_name",
        ),
        "model_path": _require_state_path(model_path, "run model_path"),
        "api_port": _validate_port(api_port, "run api_port"),
        "dist_port": _validate_port(dist_port, "run dist_port"),
        "ranks": ranks,
    }


def record_rank_container_id(
    state_root: pathlib.Path,
    run_id: str,
    rank: int,
    container_id: str,
) -> None:
    """Bind one released rank to Docker's immutable container ID.

    The ID may be written exactly once. Older records without the field are
    rejected so a name-and-label match can never authorize a later mutation.
    """
    if isinstance(rank, bool) or not isinstance(rank, int) or rank not in range(4):
        raise StateError("run rank must be 0, 1, 2, or 3")
    validated_id = _require_container_id(container_id, "run rank container_id")
    current = read_run_state(state_root, run_id)
    data = current.data
    if not isinstance(data, Mapping) or not isinstance(data.get("ranks"), list):
        raise StateError("run state data does not describe rank records")
    ranks = data["ranks"]
    if len(ranks) != 4:
        raise StateError("run state must describe exactly four ranks")

    updated_ranks: list[dict[str, Any]] = []
    for index, raw_rank in enumerate(ranks):
        if not isinstance(raw_rank, Mapping) or raw_rank.get("rank") != index:
            raise StateError(f"run rank {index} is out of order")
        if "container_id" not in raw_rank:
            raise StateError("run state lacks immutable rank container IDs")
        recorded_id = raw_rank["container_id"]
        if index == rank:
            if recorded_id not in {"", validated_id}:
                raise StateError("run rank container ID is already bound differently")
        elif recorded_id != "":
            _require_container_id(recorded_id, "run rank container_id")
        updated_rank = dict(raw_rank)
        if index == rank:
            updated_rank["container_id"] = validated_id
        updated_ranks.append(updated_rank)

    updated_data = dict(data)
    updated_data["ranks"] = updated_ranks
    write_run_state(
        state_root,
        dataclasses.replace(current, data=updated_data),
    )


def _export_run_fields(state: RunState) -> None:
    data = state.data
    if not isinstance(data, Mapping):
        raise StateError("run state data must be a JSON object")
    expected_keys = {
        "owner",
        "profile_name",
        "image_reference",
        "served_model_name",
        "model_path",
        "api_port",
        "dist_port",
        "ranks",
    }
    if set(data) != expected_keys:
        raise StateError("run state data has missing or unknown fields")
    ranks = data["ranks"]
    if not isinstance(ranks, list) or len(ranks) != 4:
        raise StateError("run state must describe exactly four ranks")

    values = [
        state.status,
        state.config_digest,
        state.lock_digest,
        _validate_identifier(data["owner"], "run owner"),
        str(data["image_reference"]),
        _validate_identifier(data["profile_name"], "run profile_name"),
        _validate_identifier(data["served_model_name"], "run served_model_name"),
        _require_state_path(data["model_path"], "run model_path"),
        str(_validate_port(data["api_port"], "run api_port")),
        str(_validate_port(data["dist_port"], "run dist_port")),
        str(len(ranks)),
    ]
    if not IMAGE_REFERENCE_PATTERN.fullmatch(str(data["image_reference"])):
        raise StateError("run image reference is malformed")
    for index, rank_record in enumerate(ranks):
        if not isinstance(rank_record, Mapping):
            raise StateError(f"run rank {index} must be a JSON object")
        if rank_record.get("rank") != index:
            raise StateError(f"run rank {index} is out of order")
        expected_rank_keys = {
            "rank",
            "node_id",
            "ssh_alias",
            "fabric_ipv4",
            "remote_root",
            "hf_cache_root",
            "container_name",
            "container_id",
            "argv",
            "mounts",
            "prelaunch_services",
            "rollback_actions",
        }
        if set(rank_record) != expected_rank_keys:
            raise StateError(f"run rank {index} has missing or unknown fields")
        container_id = rank_record.get("container_id")
        if container_id != "":
            container_id = _require_container_id(
                container_id,
                "run rank container_id",
            )
        services = rank_record.get("prelaunch_services")
        if not isinstance(services, list):
            raise StateError(f"run rank {index} pre-launch services are malformed")
        values.extend(
            (
                str(index),
                _validate_identifier(rank_record.get("node_id"), "run node_id"),
                _validate_identifier(rank_record.get("ssh_alias"), "run ssh_alias"),
                _require_state_ipv4(
                    rank_record.get("fabric_ipv4"),
                    "run fabric_ipv4",
                ),
                _require_state_path(rank_record.get("remote_root"), "run remote_root"),
                _require_state_path(
                    rank_record.get("hf_cache_root"),
                    "run hf_cache_root",
                ),
                _require_container_name(
                    rank_record.get("container_name"),
                    "run container_name",
                ),
                container_id,
                str(len(services)),
            )
        )
        for service in services:
            if not isinstance(service, Mapping):
                raise StateError(f"run rank {index} has a malformed service record")
            values.extend(
                (
                    _require_container_id(
                        service.get("container_id"),
                        "run service container_id",
                    ),
                    _require_container_name(
                        service.get("name"),
                        "run service name",
                    ),
                    _require_safe_argument(
                        str(service.get("image")),
                        "run service image",
                    ),
                    _validate_identifier(service.get("state"), "run service state"),
                )
            )
    for value in values:
        sys.stdout.buffer.write(value.encode("utf-8") + b"\0")


def _decode_probe_payload(text: str) -> Mapping[str, Any]:
    try:
        payload = json.loads(text)
    except (TypeError, ValueError) as exc:
        raise StateError("the serving probe response is not JSON") from exc
    if not isinstance(payload, Mapping):
        raise StateError("the serving probe response is not a JSON object")
    return payload


def check_model_info(text: str, expected_model_path: str) -> None:
    """Prove that the probed endpoint serves this run's pinned model snapshot.

    SGLang's /get_model_info reports model_path, tokenizer_path and
    is_generation. The pinned snapshot path carries the model revision, so an
    exact match rejects both an unrelated HTTP listener and a different model.
    """
    payload = _decode_probe_payload(text)
    if payload.get("model_path") != expected_model_path:
        raise StateError("the served model path does not match the recorded run")
    if payload.get("is_generation") is not True:
        raise StateError("the probed endpoint is not serving a generation model")


def check_served_models(text: str, expected_served_name: str) -> None:
    """Prove that /v1/models advertises exactly this run's served model name."""
    payload = _decode_probe_payload(text)
    entries = payload.get("data")
    if not isinstance(entries, list) or not entries:
        raise StateError("the served model listing is empty or malformed")
    observed = []
    for entry in entries:
        if not isinstance(entry, Mapping):
            raise StateError("the served model listing has a malformed entry")
        observed.append(entry.get("id"))
    if observed != [expected_served_name]:
        raise StateError("the served model name does not match the recorded run")


def _parse_detail(pairs: list[str]) -> dict[str, Any]:
    detail: dict[str, Any] = {}
    for pair in pairs:
        key, separator, value = pair.partition("=")
        if not separator:
            raise StateError("event detail must use KEY=VALUE")
        identifier = _validate_identifier(key, "event detail key")
        if identifier in detail:
            raise StateError(f"event detail repeats key: {identifier}")
        detail[identifier] = value
    return detail


def _utc_now() -> str:
    now = datetime.datetime.now(datetime.timezone.utc)
    return now.strftime("%Y-%m-%dT%H:%M:%S.%fZ")


def _build_argument_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="config_state.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    validate_parser = subparsers.add_parser("validate")
    validate_parser.add_argument("--config", required=True, type=pathlib.Path)
    validate_parser.add_argument("--lock", required=True, type=pathlib.Path)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("--config", required=True, type=pathlib.Path)
    export_parser.add_argument("--field", required=True)

    doctor_export_parser = subparsers.add_parser("doctor-export")
    doctor_export_parser.add_argument("--config", required=True, type=pathlib.Path)
    prepare_export_parser = subparsers.add_parser("prepare-export")
    prepare_export_parser.add_argument("--config", required=True, type=pathlib.Path)
    prepare_export_parser.add_argument("--lock", required=True, type=pathlib.Path)

    lifecycle_export_parser = subparsers.add_parser("lifecycle-export")
    lifecycle_export_parser.add_argument("--config", required=True, type=pathlib.Path)
    lifecycle_export_parser.add_argument("--lock", required=True, type=pathlib.Path)

    record_run_parser = subparsers.add_parser("record-run")
    record_run_parser.add_argument("--state-root", required=True, type=pathlib.Path)
    record_run_parser.add_argument("--run-id", required=True)
    record_run_parser.add_argument("--config-digest", required=True)
    record_run_parser.add_argument("--lock-digest", required=True)
    record_run_parser.add_argument("--status", required=True)
    record_run_parser.add_argument("--owner", required=True)
    record_run_parser.add_argument("--profile-name", required=True)
    record_run_parser.add_argument("--image-reference", required=True)
    record_run_parser.add_argument("--served-model-name", required=True)
    record_run_parser.add_argument("--model-path", required=True)
    record_run_parser.add_argument("--api-port", required=True, type=int)
    record_run_parser.add_argument("--dist-port", required=True, type=int)

    set_status_parser = subparsers.add_parser("set-run-status")
    set_status_parser.add_argument("--state-root", required=True, type=pathlib.Path)
    set_status_parser.add_argument("--run-id", required=True)
    set_status_parser.add_argument("--status", required=True)

    run_export_parser = subparsers.add_parser("run-export")
    run_export_parser.add_argument("--state-root", required=True, type=pathlib.Path)
    run_export_parser.add_argument("--run-id", required=True)

    rank_id_parser = subparsers.add_parser("record-rank-container-id")
    rank_id_parser.add_argument("--state-root", required=True, type=pathlib.Path)
    rank_id_parser.add_argument("--run-id", required=True)
    rank_id_parser.add_argument("--rank", required=True, type=int)
    rank_id_parser.add_argument("--container-id", required=True)

    append_event_parser = subparsers.add_parser("append-event")
    append_event_parser.add_argument("--state-root", required=True, type=pathlib.Path)
    append_event_parser.add_argument("--run-id", required=True)
    append_event_parser.add_argument("--phase", required=True)
    append_event_parser.add_argument("--action", required=True)
    append_event_parser.add_argument("--status", required=True)
    append_event_parser.add_argument("--detail", action="append", default=[])

    model_info_parser = subparsers.add_parser("check-model-info")
    model_info_parser.add_argument("--expected-model-path", required=True)

    served_models_parser = subparsers.add_parser("check-served-models")
    served_models_parser.add_argument("--expected-served-name", required=True)
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_argument_parser()
    options = parser.parse_args(arguments)
    try:
        if options.command == "validate":
            load_cluster(options.config)
            load_reproduction_lock(options.lock)
            return 0
        if options.command == "export":
            cluster = load_cluster(options.config)
            print(_export_cluster_field(cluster, options.field))
            return 0
        if options.command == "doctor-export":
            cluster = load_cluster(options.config)
            _export_doctor_fields(cluster)
            return 0
        if options.command == "prepare-export":
            cluster = load_cluster(options.config)
            lock = load_reproduction_lock(options.lock)
            _export_prepare_fields(cluster, lock)
            return 0
        if options.command == "lifecycle-export":
            cluster = load_cluster(options.config)
            lock = load_reproduction_lock(options.lock)
            _export_lifecycle_fields(cluster, lock)
            return 0
        if options.command == "record-run":
            write_run_state(
                options.state_root,
                RunState(
                    version=STATE_VERSION,
                    run_id=options.run_id,
                    config_digest=options.config_digest,
                    lock_digest=options.lock_digest,
                    created_at=_utc_now(),
                    status=options.status,
                    data=_build_run_data(
                        options.owner,
                        options.profile_name,
                        options.image_reference,
                        options.served_model_name,
                        options.model_path,
                        options.api_port,
                        options.dist_port,
                        _parse_launch_records(sys.stdin.read()),
                    ),
                ),
            )
            return 0
        if options.command == "set-run-status":
            current = read_run_state(options.state_root, options.run_id)
            write_run_state(
                options.state_root,
                dataclasses.replace(current, status=options.status),
            )
            return 0
        if options.command == "run-export":
            _export_run_fields(read_run_state(options.state_root, options.run_id))
            return 0
        if options.command == "record-rank-container-id":
            record_rank_container_id(
                options.state_root,
                options.run_id,
                options.rank,
                options.container_id,
            )
            return 0
        if options.command == "append-event":
            existing = read_run_events(options.state_root, options.run_id)
            append_run_event(
                options.state_root,
                options.run_id,
                RunEvent(
                    sequence=len(existing) + 1,
                    recorded_at=_utc_now(),
                    phase=options.phase,
                    action=options.action,
                    status=options.status,
                    detail=_parse_detail(options.detail),
                ),
            )
            return 0
        if options.command == "check-model-info":
            check_model_info(sys.stdin.read(), options.expected_model_path)
            return 0
        if options.command == "check-served-models":
            check_served_models(sys.stdin.read(), options.expected_served_name)
            return 0
    except (ConfigError, StateError) as exc:
        print(f"config_state: error: {exc}", file=sys.stderr)
        return 2
    parser.error(f"unsupported command: {options.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
