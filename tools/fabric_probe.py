#!/usr/bin/env python3

from __future__ import annotations

import argparse
import dataclasses
import ipaddress
import json
import os
import pathlib
import re
import stat
import sys
from collections.abc import Mapping
from typing import Any

if __package__ in {None, ""}:
    sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from tools.config_state import load_cluster, load_reproduction_lock


STORAGE_HEADROOM_PERCENT = 20
IDENTIFIER_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\Z")
DIGEST_PATTERN = re.compile(r"\A[0-9a-f]{64}\Z")
FINDING_ID_PATTERN = re.compile(r"\A[A-Za-z0-9][A-Za-z0-9._-]*\Z")


class ProbeError(ValueError):
    """Raised when probe data is malformed or unsafe."""


@dataclasses.dataclass(frozen=True)
class Finding:
    id: str
    ok: bool
    summary: str

    def to_json(self) -> dict[str, object]:
        return {
            "id": self.id,
            "ok": self.ok,
            "summary": self.summary,
        }


@dataclasses.dataclass(frozen=True)
class Requirements:
    node_identities: Mapping[str, str]
    node_fabric_ipv4: Mapping[str, str]
    source_node_id: str
    fabric_ipv4_cidr: str
    require_rdma: bool
    api_port: int
    distributed_port: int
    minimum_storage_bytes: int


@dataclasses.dataclass(frozen=True)
class FabricTuple:
    interface: str
    ipv4: str
    rdma_device: str
    rdma_state: str


@dataclasses.dataclass(frozen=True)
class NodeProbe:
    id: str
    machine_id_sha256: str
    architecture: str
    gpu_name: str
    nvidia_visible: bool
    storage_available_bytes: int
    docker_available: bool
    cdi_available: bool
    api_port_available: bool
    distributed_port_available: bool
    egress_available: bool
    fabric: FabricTuple
    reachable_node_ids: tuple[str, ...]


@dataclasses.dataclass(frozen=True)
class FabricSnapshot:
    requirements: Requirements
    nodes: tuple[NodeProbe, ...]


def _load_json(payload: str) -> Any:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, value in pairs:
            if key in result:
                raise ProbeError(f"duplicate JSON key: {key}")
            result[key] = value
        return result

    def reject_non_finite(value: str) -> None:
        raise ProbeError(f"non-finite JSON number is not allowed: {value}")

    try:
        return json.loads(
            payload,
            object_pairs_hook=reject_duplicate_keys,
            parse_constant=reject_non_finite,
        )
    except json.JSONDecodeError as exc:
        raise ProbeError("probe payload is not valid JSON") from exc


def _object(value: Any, location: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ProbeError(f"{location} must be an object")
    return value


def _exact_keys(
    value: Mapping[str, Any],
    expected: set[str],
    location: str,
) -> None:
    unknown = sorted(set(value) - expected)
    missing = sorted(expected - set(value))
    if unknown:
        raise ProbeError(f"{location} contains unknown fields")
    if missing:
        raise ProbeError(f"{location} is missing required fields")


def _string(
    value: Any,
    location: str,
    *,
    allow_empty: bool = False,
) -> str:
    if not isinstance(value, str):
        raise ProbeError(f"{location} must be a string")
    if not allow_empty and not value:
        raise ProbeError(f"{location} must not be empty")
    if any(ord(character) < 32 or ord(character) == 127 for character in value):
        raise ProbeError(f"{location} contains control characters")
    return value


def _identifier(value: Any, location: str) -> str:
    identifier = _string(value, location)
    if not IDENTIFIER_PATTERN.fullmatch(identifier) or identifier in {".", ".."}:
        raise ProbeError(f"{location} must be a safe identifier")
    return identifier


def _boolean(value: Any, location: str) -> bool:
    if not isinstance(value, bool):
        raise ProbeError(f"{location} must be a boolean")
    return value


def _integer(value: Any, location: str, minimum: int = 0) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise ProbeError(f"{location} must be an integer of at least {minimum}")
    return value


def _port(value: Any, location: str) -> int:
    port = _integer(value, location, 1)
    if port > 65535:
        raise ProbeError(f"{location} must be at most 65535")
    return port


def _digest(value: Any, location: str) -> str:
    digest = _string(value, location)
    if not DIGEST_PATTERN.fullmatch(digest):
        raise ProbeError(f"{location} must be a lowercase SHA-256 digest")
    return digest


def _parse_requirements(value: Any) -> Requirements:
    raw = _object(value, "requirements")
    _exact_keys(
        raw,
        {
            "node_identities",
            "node_fabric_ipv4",
            "source_node_id",
            "fabric_ipv4_cidr",
            "require_rdma",
            "api_port",
            "distributed_port",
            "minimum_storage_bytes",
        },
        "requirements",
    )
    identities_raw = _object(raw["node_identities"], "requirements.node_identities")
    if len(identities_raw) != 4:
        raise ProbeError("requirements.node_identities must contain four nodes")
    identities: dict[str, str] = {}
    for raw_node_id, raw_digest in identities_raw.items():
        node_id = _identifier(raw_node_id, "requirements node ID")
        identities[node_id] = _digest(
            raw_digest,
            f"requirements.node_identities.{node_id}",
        )
    source_node_id = _identifier(
        raw["source_node_id"],
        "requirements.source_node_id",
    )
    if source_node_id not in identities:
        raise ProbeError("requirements.source_node_id is not a configured node")
    cidr = _string(raw["fabric_ipv4_cidr"], "requirements.fabric_ipv4_cidr")
    try:
        network = ipaddress.ip_network(cidr, strict=True)
    except ValueError as exc:
        raise ProbeError("requirements.fabric_ipv4_cidr is invalid") from exc
    if not isinstance(network, ipaddress.IPv4Network):
        raise ProbeError("requirements.fabric_ipv4_cidr must be IPv4")
    fabric_raw = _object(
        raw["node_fabric_ipv4"],
        "requirements.node_fabric_ipv4",
    )
    if set(fabric_raw) != set(identities):
        raise ProbeError("requirements.node_fabric_ipv4 must cover configured nodes")
    fabric_addresses: dict[str, str] = {}
    for node_id, raw_address in fabric_raw.items():
        address_text = _string(
            raw_address,
            f"requirements.node_fabric_ipv4.{node_id}",
        )
        try:
            address = ipaddress.ip_address(address_text)
        except ValueError as exc:
            raise ProbeError("configured fabric address is invalid") from exc
        if (
            not isinstance(address, ipaddress.IPv4Address)
            or address not in network
            or address in {network.network_address, network.broadcast_address}
        ):
            raise ProbeError("configured fabric address is outside the usable CIDR")
        fabric_addresses[node_id] = str(address)
    if len(set(fabric_addresses.values())) != len(fabric_addresses):
        raise ProbeError("configured fabric addresses must be unique")
    require_rdma = _boolean(raw["require_rdma"], "requirements.require_rdma")
    return Requirements(
        node_identities=identities,
        node_fabric_ipv4=fabric_addresses,
        source_node_id=source_node_id,
        fabric_ipv4_cidr=str(network),
        require_rdma=require_rdma,
        api_port=_port(raw["api_port"], "requirements.api_port"),
        distributed_port=_port(
            raw["distributed_port"],
            "requirements.distributed_port",
        ),
        minimum_storage_bytes=_integer(
            raw["minimum_storage_bytes"],
            "requirements.minimum_storage_bytes",
            1,
        ),
    )


def _parse_fabric_tuple(value: Any, location: str) -> FabricTuple:
    raw = _object(value, location)
    _exact_keys(
        raw,
        {"interface", "ipv4", "rdma_device", "rdma_state"},
        location,
    )
    ipv4 = _string(raw["ipv4"], f"{location}.ipv4")
    try:
        address = ipaddress.ip_address(ipv4)
    except ValueError as exc:
        raise ProbeError(f"{location}.ipv4 must be an IPv4 address") from exc
    if not isinstance(address, ipaddress.IPv4Address):
        raise ProbeError(f"{location}.ipv4 must be an IPv4 address")
    return FabricTuple(
        interface=_string(
            raw["interface"],
            f"{location}.interface",
            allow_empty=True,
        ),
        ipv4=str(address),
        rdma_device=_string(
            raw["rdma_device"],
            f"{location}.rdma_device",
            allow_empty=True,
        ),
        rdma_state=_string(
            raw["rdma_state"],
            f"{location}.rdma_state",
            allow_empty=True,
        ),
    )


def _parse_node(
    value: Any,
    location: str,
    expected_node_ids: set[str] | None,
) -> NodeProbe:
    raw = _object(value, location)
    _exact_keys(
        raw,
        {
            "id",
            "machine_id_sha256",
            "architecture",
            "gpu_name",
            "nvidia_visible",
            "storage_available_bytes",
            "docker_available",
            "cdi_available",
            "api_port_available",
            "distributed_port_available",
            "egress_available",
            "fabric",
            "reachable_node_ids",
        },
        location,
    )
    node_id = _identifier(raw["id"], f"{location}.id")
    if expected_node_ids is not None and node_id not in expected_node_ids:
        raise ProbeError(f"{location}.id is not configured")
    reachable_raw = raw["reachable_node_ids"]
    if not isinstance(reachable_raw, list):
        raise ProbeError(f"{location}.reachable_node_ids must be an array")
    reachable = tuple(
        _identifier(item, f"{location}.reachable_node_ids")
        for item in reachable_raw
    )
    if len(set(reachable)) != len(reachable):
        raise ProbeError(f"{location}.reachable_node_ids contains duplicate nodes")
    if node_id in reachable:
        raise ProbeError(f"{location}.reachable_node_ids contains itself")
    if expected_node_ids is not None and not set(reachable) <= expected_node_ids:
        raise ProbeError(f"{location}.reachable_node_ids contains unknown nodes")
    machine_id = _string(
        raw["machine_id_sha256"],
        f"{location}.machine_id_sha256",
        allow_empty=True,
    )
    if machine_id and not DIGEST_PATTERN.fullmatch(machine_id):
        raise ProbeError(f"{location}.machine_id_sha256 is malformed")
    return NodeProbe(
        id=node_id,
        machine_id_sha256=machine_id,
        architecture=_string(
            raw["architecture"],
            f"{location}.architecture",
            allow_empty=True,
        ),
        gpu_name=_string(
            raw["gpu_name"],
            f"{location}.gpu_name",
            allow_empty=True,
        ),
        nvidia_visible=_boolean(
            raw["nvidia_visible"],
            f"{location}.nvidia_visible",
        ),
        storage_available_bytes=_integer(
            raw["storage_available_bytes"],
            f"{location}.storage_available_bytes",
        ),
        docker_available=_boolean(
            raw["docker_available"],
            f"{location}.docker_available",
        ),
        cdi_available=_boolean(
            raw["cdi_available"],
            f"{location}.cdi_available",
        ),
        api_port_available=_boolean(
            raw["api_port_available"],
            f"{location}.api_port_available",
        ),
        distributed_port_available=_boolean(
            raw["distributed_port_available"],
            f"{location}.distributed_port_available",
        ),
        egress_available=_boolean(
            raw["egress_available"],
            f"{location}.egress_available",
        ),
        fabric=_parse_fabric_tuple(raw["fabric"], f"{location}.fabric"),
        reachable_node_ids=reachable,
    )


def parse_probe(payload: str) -> FabricSnapshot:
    root = _object(_load_json(payload), "probe")
    _exact_keys(root, {"requirements", "nodes"}, "probe")
    requirements = _parse_requirements(root["requirements"])
    raw_nodes = root["nodes"]
    if not isinstance(raw_nodes, list) or len(raw_nodes) > 4:
        raise ProbeError("probe.nodes must contain at most four nodes")
    expected_node_ids = set(requirements.node_identities)
    raw_node_ids = [
        _identifier(
            _object(raw_node, f"probe.nodes[{index}]").get("id"),
            f"probe.nodes[{index}].id",
        )
        for index, raw_node in enumerate(raw_nodes)
    ]
    if len(set(raw_node_ids)) != len(raw_node_ids):
        raise ProbeError("probe.nodes contains duplicate node IDs")
    nodes = tuple(
        _parse_node(raw_node, f"probe.nodes[{index}]", expected_node_ids)
        for index, raw_node in enumerate(raw_nodes)
    )
    return FabricSnapshot(requirements=requirements, nodes=nodes)


def _node_findings(
    node_id: str,
    node: NodeProbe | None,
    requirements: Requirements,
) -> list[Finding]:
    present = node is not None
    findings = [
        Finding(
            f"node.{node_id}.ssh",
            present,
            "remote probe available" if present else "remote probe unavailable",
        )
    ]
    checks: tuple[tuple[str, bool, str, str], ...]
    if node is None:
        checks = (
            ("identity", False, "remote identity matches", "remote identity mismatch"),
            ("architecture", False, "architecture is aarch64", "architecture is not aarch64"),
            ("gpu", False, "NVIDIA GB10 GPU is visible", "NVIDIA GB10 GPU is unavailable"),
            ("storage", False, "storage includes artifact headroom", "storage is below artifact headroom"),
            ("docker", False, "Docker is available", "Docker is unavailable"),
            ("cdi", False, "NVIDIA CDI is available", "NVIDIA CDI is unavailable"),
            ("api_port", False, "API port is available", "API port is unavailable"),
            (
                "distributed_port",
                False,
                "distributed port is available",
                "distributed port is unavailable",
            ),
            ("fabric_tuple", False, "fabric tuple is in configured CIDR", "fabric tuple is invalid"),
            ("rdma", False, "RDMA link is ACTIVE", "RDMA link is not ACTIVE"),
        )
    else:
        gpu_name = node.gpu_name.lower()
        gpu_ok = node.nvidia_visible and (
            "gb10" in gpu_name or "dgx spark" in gpu_name
        )
        network = ipaddress.ip_network(requirements.fabric_ipv4_cidr)
        address = ipaddress.ip_address(node.fabric.ipv4)
        fabric_ok = (
            address in network
            and address not in {network.network_address, network.broadcast_address}
            and node.fabric.ipv4 == requirements.node_fabric_ipv4[node_id]
            and bool(node.fabric.interface)
            and bool(node.fabric.rdma_device)
        )
        rdma_ok = not requirements.require_rdma or node.fabric.rdma_state == "ACTIVE"
        checks = (
            (
                "identity",
                node.machine_id_sha256 == requirements.node_identities[node_id],
                "remote identity matches",
                "remote identity mismatch",
            ),
            (
                "architecture",
                node.architecture == "aarch64",
                "architecture is aarch64",
                "architecture is not aarch64",
            ),
            (
                "gpu",
                gpu_ok,
                "NVIDIA GB10 GPU is visible",
                "NVIDIA GB10 GPU is unavailable",
            ),
            (
                "storage",
                node.storage_available_bytes >= requirements.minimum_storage_bytes,
                "storage includes artifact headroom",
                "storage is below artifact headroom",
            ),
            (
                "docker",
                node.docker_available,
                "Docker is available",
                "Docker is unavailable",
            ),
            (
                "cdi",
                node.cdi_available,
                "NVIDIA CDI is available",
                "NVIDIA CDI is unavailable",
            ),
            (
                "api_port",
                node.api_port_available,
                "API port is available",
                "API port is unavailable",
            ),
            (
                "distributed_port",
                node.distributed_port_available,
                "distributed port is available",
                "distributed port is unavailable",
            ),
            (
                "fabric_tuple",
                fabric_ok,
                "fabric tuple is in configured CIDR",
                "fabric tuple is invalid",
            ),
            (
                "rdma",
                rdma_ok,
                "RDMA link is ACTIVE",
                "RDMA link is not ACTIVE",
            ),
        )
    findings.extend(
        Finding(
            id=f"node.{node_id}.{check_id}",
            ok=ok,
            summary=success_summary if ok else failure_summary,
        )
        for check_id, ok, success_summary, failure_summary in checks
    )
    if node_id == requirements.source_node_id:
        egress_ok = node is not None and node.egress_available
        findings.append(
            Finding(
                id=f"node.{node_id}.egress",
                ok=egress_ok,
                summary=(
                    "source-node egress is available"
                    if egress_ok
                    else "source-node egress is unavailable"
                ),
            )
        )
    return findings


def evaluate_fabric(snapshot: FabricSnapshot) -> list[Finding]:
    if not isinstance(snapshot, FabricSnapshot):
        raise ProbeError("evaluate_fabric requires a FabricSnapshot")
    requirements = snapshot.requirements
    observed = {node.id: node for node in snapshot.nodes}
    findings: list[Finding] = []
    for node_id in requirements.node_identities:
        findings.extend(_node_findings(node_id, observed.get(node_id), requirements))

    tuples = [
        (node.fabric.interface, node.fabric.ipv4, node.fabric.rdma_device)
        for node in snapshot.nodes
    ]
    addresses = [node.fabric.ipv4 for node in snapshot.nodes]
    unique_ok = (
        len(snapshot.nodes) == len(requirements.node_identities)
        and len(set(tuples)) == len(tuples)
        and len(set(addresses)) == len(addresses)
    )
    findings.append(
        Finding(
            id="fabric.unique_tuples",
            ok=unique_ok,
            summary=(
                "fabric tuples are unique"
                if unique_ok
                else "fabric tuples are missing or duplicated"
            ),
        )
    )

    ordered_ids = tuple(requirements.node_identities)
    for left_index, left_id in enumerate(ordered_ids):
        for right_id in ordered_ids[left_index + 1 :]:
            left = observed.get(left_id)
            right = observed.get(right_id)
            path_ok = (
                left is not None
                and right is not None
                and right_id in left.reachable_node_ids
                and left_id in right.reachable_node_ids
            )
            findings.append(
                Finding(
                    id=f"fabric.pair.{left_id}.{right_id}",
                    ok=path_ok,
                    summary=(
                        "bidirectional fabric path available"
                        if path_ok
                        else "bidirectional fabric path unavailable"
                    ),
                )
            )
    return findings


def _requirements_payload(config_path: pathlib.Path, lock_path: pathlib.Path) -> dict[str, Any]:
    cluster = load_cluster(config_path)
    lock = load_reproduction_lock(lock_path)
    artifact_bytes = lock.target_model.hub_bytes + lock.draft_model.tensor_bytes
    minimum_storage_bytes = (
        artifact_bytes * (100 + STORAGE_HEADROOM_PERCENT) + 99
    ) // 100
    source_node = next(node for node in cluster.nodes if node.role == "source")
    return {
        "node_identities": {
            node.id: node.expected_machine_id_sha256 for node in cluster.nodes
        },
        "node_fabric_ipv4": {
            node.id: node.fabric_ipv4 for node in cluster.nodes
        },
        "source_node_id": source_node.id,
        "fabric_ipv4_cidr": cluster.fabric.ipv4_cidr,
        "require_rdma": cluster.fabric.require_rdma,
        "api_port": cluster.ports.api,
        "distributed_port": cluster.ports.distributed,
        "minimum_storage_bytes": minimum_storage_bytes,
    }


def _compact_json(value: Any) -> str:
    return json.dumps(
        value,
        allow_nan=False,
        ensure_ascii=True,
        separators=(",", ":"),
    )


def _read_stdin() -> str:
    try:
        return sys.stdin.read()
    except OSError as exc:
        raise ProbeError("cannot read probe input") from exc


def _normalize_node(expected_node_id: str) -> int:
    node = _parse_node(_load_json(_read_stdin()), "node", {expected_node_id})
    if node.id != expected_node_id:
        raise ProbeError("node.id does not match the requested node")
    print(_compact_json(dataclasses.asdict(node)))
    return 0


def _normalize_reachability(expected_node_id: str) -> int:
    raw = _object(_load_json(_read_stdin()), "reachability")
    _exact_keys(raw, {"id", "reachable_node_ids"}, "reachability")
    node_id = _identifier(raw["id"], "reachability.id")
    if node_id != expected_node_id:
        raise ProbeError("reachability.id does not match the requested node")
    reachable_raw = raw["reachable_node_ids"]
    if not isinstance(reachable_raw, list):
        raise ProbeError("reachability.reachable_node_ids must be an array")
    reachable = [
        _identifier(item, "reachability.reachable_node_ids")
        for item in reachable_raw
    ]
    if len(reachable) != len(set(reachable)) or node_id in reachable:
        raise ProbeError("reachability node list is invalid")
    print(
        _compact_json(
            {"id": node_id, "reachable_node_ids": reachable},
        )
    )
    return 0


def _extract_addresses() -> int:
    raw_nodes = _load_json(_read_stdin())
    if not isinstance(raw_nodes, list):
        raise ProbeError("nodes input must be an array")
    parsed = [
        _parse_node(raw, f"nodes[{index}]", None)
        for index, raw in enumerate(raw_nodes)
    ]
    if len({node.id for node in parsed}) != len(parsed):
        raise ProbeError("nodes input contains duplicate node IDs")
    for node in parsed:
        print(f"{node.id}={node.fabric.ipv4}")
    return 0


def _merge_reachability() -> int:
    root = _object(_load_json(_read_stdin()), "merge")
    _exact_keys(root, {"nodes", "reachability"}, "merge")
    raw_nodes = root["nodes"]
    raw_reachability = root["reachability"]
    if not isinstance(raw_nodes, list) or not isinstance(raw_reachability, list):
        raise ProbeError("merge inputs must be arrays")
    nodes = [
        _parse_node(raw, f"merge.nodes[{index}]", None)
        for index, raw in enumerate(raw_nodes)
    ]
    reaches: dict[str, list[str]] = {}
    for index, raw in enumerate(raw_reachability):
        value = _object(raw, f"merge.reachability[{index}]")
        _exact_keys(
            value,
            {"id", "reachable_node_ids"},
            f"merge.reachability[{index}]",
        )
        node_id = _identifier(value["id"], f"merge.reachability[{index}].id")
        raw_ids = value["reachable_node_ids"]
        if not isinstance(raw_ids, list):
            raise ProbeError("merge reachability IDs must be an array")
        if node_id in reaches:
            raise ProbeError("merge contains duplicate reachability nodes")
        reaches[node_id] = [
            _identifier(item, "merge reachability node ID") for item in raw_ids
        ]
    merged = []
    for node in nodes:
        value = dataclasses.asdict(node)
        value["reachable_node_ids"] = reaches.get(node.id, [])
        merged.append(value)
    print(_compact_json(merged))
    return 0


def _evaluate(config_path: pathlib.Path, lock_path: pathlib.Path) -> int:
    raw_nodes = _load_json(_read_stdin())
    if not isinstance(raw_nodes, list):
        raise ProbeError("evaluate input must be an array")
    payload = {
        "requirements": _requirements_payload(config_path, lock_path),
        "nodes": raw_nodes,
    }
    findings = evaluate_fabric(parse_probe(_compact_json(payload)))
    print(_compact_json([finding.to_json() for finding in findings]))
    return 0


def _finding_from_json(value: Any, location: str) -> Finding:
    raw = _object(value, location)
    _exact_keys(raw, {"id", "ok", "summary"}, location)
    finding_id = _string(raw["id"], f"{location}.id")
    if not FINDING_ID_PATTERN.fullmatch(finding_id):
        raise ProbeError(f"{location}.id is malformed")
    summary = _string(raw["summary"], f"{location}.summary")
    if len(summary) > 160:
        raise ProbeError(f"{location}.summary is too long")
    return Finding(
        id=finding_id,
        ok=_boolean(raw["ok"], f"{location}.ok"),
        summary=summary,
    )


def _render(output_format: str) -> int:
    raw_findings = _load_json(_read_stdin())
    if not isinstance(raw_findings, list):
        raise ProbeError("render input must be an array")
    findings = [
        _finding_from_json(value, f"findings[{index}]")
        for index, value in enumerate(raw_findings)
    ]
    failed = sum(not finding.ok for finding in findings)
    passed = len(findings) - failed
    status = "failed" if failed else "healthy"
    if output_format == "json":
        print(
            _compact_json(
                {
                    "status": status,
                    "findings": [finding.to_json() for finding in findings],
                    "summary": {"passed": passed, "failed": failed},
                }
            )
        )
    else:
        for finding in findings:
            label = "PASS" if finding.ok else "FAIL"
            print(f"{label} {finding.id}: {finding.summary}")
        print(f"SUMMARY {status}: {passed} passed, {failed} failed")
    return 1 if failed else 0


def _known_hosts_state(path: pathlib.Path) -> int:
    try:
        path_stat = path.lstat()
    except OSError:
        return 1
    mode = path_stat.st_mode
    if not stat.S_ISREG(mode) or stat.S_ISLNK(mode):
        return 1
    if path_stat.st_uid != os.geteuid():
        return 1
    if stat.S_IMODE(mode) & 0o022:
        return 1
    return 0


def _expand_known_hosts(path: str) -> int:
    if not path or any(ord(character) < 32 or ord(character) == 127 for character in path):
        raise ProbeError("known-hosts path is invalid")
    try:
        expanded = pathlib.Path(path).expanduser()
    except RuntimeError as exc:
        raise ProbeError("known-hosts path cannot be expanded") from exc
    print(str(expanded))
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="fabric_probe.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    normalize = subparsers.add_parser("normalize-node")
    normalize.add_argument("--expected-node-id", required=True)

    normalize_reachability = subparsers.add_parser("normalize-reachability")
    normalize_reachability.add_argument("--expected-node-id", required=True)

    subparsers.add_parser("extract-addresses")
    subparsers.add_parser("merge-reachability")

    evaluate = subparsers.add_parser("evaluate")
    evaluate.add_argument("--config", required=True, type=pathlib.Path)
    evaluate.add_argument("--lock", required=True, type=pathlib.Path)

    render = subparsers.add_parser("render")
    render.add_argument("--format", choices=("text", "json"), required=True)

    known_hosts = subparsers.add_parser("known-hosts-state")
    known_hosts.add_argument("--path", required=True, type=pathlib.Path)

    expand_known_hosts = subparsers.add_parser("expand-known-hosts")
    expand_known_hosts.add_argument("--path", required=True)
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_parser()
    options = parser.parse_args(arguments)
    try:
        if options.command == "normalize-node":
            return _normalize_node(options.expected_node_id)
        if options.command == "normalize-reachability":
            return _normalize_reachability(options.expected_node_id)
        if options.command == "extract-addresses":
            return _extract_addresses()
        if options.command == "merge-reachability":
            return _merge_reachability()
        if options.command == "evaluate":
            return _evaluate(options.config, options.lock)
        if options.command == "render":
            return _render(options.format)
        if options.command == "known-hosts-state":
            return _known_hosts_state(options.path)
        if options.command == "expand-known-hosts":
            return _expand_known_hosts(options.path)
    except (ProbeError, OSError, ValueError) as exc:
        print(f"fabric_probe: error: {exc}", file=sys.stderr)
        return 2
    parser.error(f"unsupported command: {options.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
