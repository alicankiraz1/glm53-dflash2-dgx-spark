#!/usr/bin/env python3

from __future__ import annotations

import argparse
import base64
import dataclasses
import hashlib
import ipaddress
import json
import os
import pathlib
import shlex
import shutil
import socket
import subprocess
import sys
from collections.abc import Callable, Sequence
from typing import Any


SSH_EXIT_FAILED = 10
SSH_EXIT_TIMEOUT = 11
SSH_EXIT_SPAWN_ERROR = 12
COMMAND_TIMEOUT_SECONDS = 10
PING_TIMEOUT_SECONDS = 5


@dataclasses.dataclass(frozen=True)
class CommandResult:
    returncode: int
    stdout: str


@dataclasses.dataclass(frozen=True)
class SSHExecution:
    exit_code: int
    stdout: str


ProcessRunner = Callable[..., subprocess.CompletedProcess[str]]
CommandRunner = Callable[[list[str], int], CommandResult]
TextReader = Callable[[pathlib.Path], str]
PathExists = Callable[[pathlib.Path], bool]
DiskUsage = Callable[[pathlib.Path], Any]
Connector = Callable[[tuple[str, int], int], Any]


def run_ssh(
    argv: Sequence[str],
    timeout_seconds: float,
    runner: ProcessRunner = subprocess.run,
) -> SSHExecution:
    command = list(argv)
    if (
        not command
        or pathlib.Path(command[0]).name != "ssh"
        or timeout_seconds <= 0
    ):
        raise ValueError("run_ssh requires an ssh command and positive timeout")
    try:
        result = runner(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except subprocess.TimeoutExpired:
        return SSHExecution(exit_code=SSH_EXIT_TIMEOUT, stdout="")
    except OSError:
        return SSHExecution(exit_code=SSH_EXIT_SPAWN_ERROR, stdout="")
    if result.returncode != 0:
        return SSHExecution(exit_code=SSH_EXIT_FAILED, stdout="")
    return SSHExecution(exit_code=0, stdout=result.stdout)


def run_command(
    command: list[str],
    timeout_seconds: int,
) -> CommandResult:
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout_seconds,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return CommandResult(returncode=127, stdout="")
    return CommandResult(returncode=result.returncode, stdout=result.stdout)


def _read_text(path: pathlib.Path) -> str:
    return path.read_text(encoding="utf-8")


def machine_id_sha256(read_text: TextReader = _read_text) -> str:
    try:
        machine_id = read_text(pathlib.Path("/etc/machine-id")).strip()
    except OSError:
        return ""
    if not machine_id:
        return ""
    return hashlib.sha256(machine_id.encode("utf-8")).hexdigest()


def select_storage_ancestor(
    remote_root: pathlib.Path,
    exists: PathExists = pathlib.Path.exists,
) -> pathlib.Path:
    candidate = remote_root
    while not exists(candidate) and candidate != candidate.parent:
        candidate = candidate.parent
    return candidate


def storage_available_bytes(
    remote_root: pathlib.Path,
    exists: PathExists = pathlib.Path.exists,
    disk_usage: DiskUsage = shutil.disk_usage,
) -> int:
    ancestor = select_storage_ancestor(remote_root, exists)
    try:
        return int(disk_usage(ancestor).free)
    except OSError:
        return 0


def port_is_available(
    port: int,
    command_runner: CommandRunner = run_command,
) -> bool:
    result = command_runner(
        ["ss", "-H", "-ltn", f"sport = :{port}"],
        COMMAND_TIMEOUT_SECONDS,
    )
    return result.returncode == 0 and not result.stdout.strip()


def select_fabric_interface(
    ipv4_cidr: str,
    address_payload: str,
) -> tuple[str, str]:
    try:
        network = ipaddress.ip_network(ipv4_cidr, strict=True)
        interfaces = json.loads(address_payload)
    except (TypeError, ValueError):
        return "", "0.0.0.0"
    if not isinstance(network, ipaddress.IPv4Network) or not isinstance(
        interfaces,
        list,
    ):
        return "", "0.0.0.0"
    for interface in interfaces:
        if not isinstance(interface, dict):
            continue
        address_info = interface.get("addr_info", [])
        if not isinstance(address_info, list):
            continue
        for raw_address in address_info:
            if not isinstance(raw_address, dict):
                continue
            try:
                candidate = ipaddress.ip_address(str(raw_address.get("local", "")))
            except ValueError:
                continue
            if (
                isinstance(candidate, ipaddress.IPv4Address)
                and candidate in network
                and candidate
                not in {network.network_address, network.broadcast_address}
            ):
                return str(interface.get("ifname", "")), str(candidate)
    return "", "0.0.0.0"


def join_rdma_link(
    fabric_interface: str,
    rdma_payload: str,
) -> tuple[str, str]:
    try:
        links = json.loads(rdma_payload)
    except (TypeError, ValueError):
        return "", ""
    if not isinstance(links, list):
        return "", ""
    for link in links:
        if not isinstance(link, dict):
            continue
        if str(link.get("netdev", "")) == fabric_interface:
            return str(link.get("ifname", "")), str(link.get("state", ""))
    return "", ""


def source_egress_available(
    role: str,
    connector: Connector = socket.create_connection,
) -> bool:
    if role != "source":
        return False
    try:
        connection = connector(("huggingface.co", 443), 5)
    except OSError:
        return False
    try:
        connection.close()
    except OSError:
        return False
    return True


def probe_reachability(
    node_id: str,
    targets: Sequence[tuple[str, str]],
    command_runner: CommandRunner = run_command,
) -> list[str]:
    reachable: list[str] = []
    for target_id, target_ipv4 in targets:
        if target_id == node_id:
            continue
        result = command_runner(
            ["ping", "-c", "1", "-W", "2", target_ipv4],
            PING_TIMEOUT_SECONDS,
        )
        if result.returncode == 0:
            reachable.append(target_id)
    return reachable


def collect_node_probe(
    node_id: str,
    role: str,
    remote_root: str,
    ipv4_cidr: str,
    api_port: int,
    distributed_port: int,
    command_runner: CommandRunner = run_command,
    read_text: TextReader = _read_text,
    exists: PathExists = pathlib.Path.exists,
    disk_usage: DiskUsage = shutil.disk_usage,
    connector: Connector = socket.create_connection,
) -> dict[str, object]:
    gpu = command_runner(
        ["nvidia-smi", "--query-gpu=name", "--format=csv,noheader"],
        COMMAND_TIMEOUT_SECONDS,
    )
    gpu_lines = gpu.stdout.splitlines()
    gpu_name = gpu_lines[0].strip() if gpu_lines else ""
    docker = command_runner(
        ["docker", "info", "--format", "{{.ServerVersion}}"],
        COMMAND_TIMEOUT_SECONDS,
    )
    cdi = command_runner(
        ["nvidia-ctk", "cdi", "list"],
        COMMAND_TIMEOUT_SECONDS,
    )
    addresses = command_runner(
        ["ip", "-j", "-4", "address", "show", "up"],
        COMMAND_TIMEOUT_SECONDS,
    )
    if addresses.returncode == 0:
        fabric_interface, fabric_ipv4 = select_fabric_interface(
            ipv4_cidr,
            addresses.stdout,
        )
    else:
        fabric_interface, fabric_ipv4 = "", "0.0.0.0"
    rdma = command_runner(
        ["rdma", "-j", "link", "show"],
        COMMAND_TIMEOUT_SECONDS,
    )
    if rdma.returncode == 0:
        rdma_device, rdma_state = join_rdma_link(
            fabric_interface,
            rdma.stdout,
        )
    else:
        rdma_device, rdma_state = "", ""
    return {
        "id": node_id,
        "machine_id_sha256": machine_id_sha256(read_text),
        "architecture": os.uname().machine,
        "gpu_name": gpu_name,
        "nvidia_visible": gpu.returncode == 0 and bool(gpu_name),
        "storage_available_bytes": storage_available_bytes(
            pathlib.Path(remote_root),
            exists,
            disk_usage,
        ),
        "docker_available": (
            docker.returncode == 0 and bool(docker.stdout.strip())
        ),
        "cdi_available": (
            cdi.returncode == 0 and "nvidia.com/gpu" in cdi.stdout
        ),
        "api_port_available": port_is_available(api_port, command_runner),
        "distributed_port_available": port_is_available(
            distributed_port,
            command_runner,
        ),
        "egress_available": source_egress_available(role, connector),
        "fabric": {
            "interface": fabric_interface,
            "ipv4": fabric_ipv4,
            "rdma_device": rdma_device,
            "rdma_state": rdma_state,
        },
        "reachable_node_ids": [],
    }


def _validate_remote_arguments(mode: str, arguments: Sequence[str]) -> None:
    if mode == "node" and len(arguments) != 6:
        raise ValueError("node mode requires six arguments")
    if mode == "reachability" and len(arguments) < 1:
        raise ValueError("reachability mode requires a node ID")


def build_remote_command(
    source: bytes,
    mode: str,
    arguments: Sequence[str],
) -> str:
    if mode not in {"node", "reachability"}:
        raise ValueError("unsupported remote probe mode")
    _validate_remote_arguments(mode, arguments)
    encoded_source = base64.b64encode(source).decode("ascii")
    bootstrap = (
        "import base64;"
        f'exec(compile(base64.b64decode("{encoded_source}"),'
        '"<node_probe>","exec"))'
    )
    argv = [
        "python3",
        "-c",
        bootstrap,
        "remote",
        "--mode",
        mode,
        "--",
        *arguments,
    ]
    return shlex.join(argv)


def _strip_separator(arguments: Sequence[str]) -> list[str]:
    result = list(arguments)
    if result and result[0] == "--":
        return result[1:]
    return result


def _run_ssh_command(timeout_seconds: float, argv: Sequence[str]) -> int:
    command = _strip_separator(argv)
    try:
        execution = run_ssh(command, timeout_seconds)
    except ValueError:
        print("node_probe: invalid ssh runner invocation", file=sys.stderr)
        return 2
    if execution.exit_code == 0:
        sys.stdout.write(execution.stdout)
        return 0
    messages = {
        SSH_EXIT_FAILED: "node_probe: ssh command failed",
        SSH_EXIT_TIMEOUT: "node_probe: ssh command timed out",
        SSH_EXIT_SPAWN_ERROR: "node_probe: ssh command could not start",
    }
    print(messages[execution.exit_code], file=sys.stderr)
    return execution.exit_code


def _encode_remote_command(mode: str, arguments: Sequence[str]) -> int:
    payload_arguments = _strip_separator(arguments)
    try:
        source = pathlib.Path(__file__).read_bytes()
        command = build_remote_command(source, mode, payload_arguments)
    except (OSError, ValueError) as exc:
        print(f"node_probe: cannot build remote command: {exc}", file=sys.stderr)
        return 2
    print(command)
    return 0


def _parse_target(value: str) -> tuple[str, str]:
    target_id, separator, target_ipv4 = value.partition("=")
    if not separator or not target_id:
        raise ValueError("reachability target is malformed")
    address = ipaddress.ip_address(target_ipv4)
    if not isinstance(address, ipaddress.IPv4Address):
        raise ValueError("reachability target must use IPv4")
    return target_id, str(address)


def _run_remote(mode: str, arguments: Sequence[str]) -> int:
    payload_arguments = _strip_separator(arguments)
    try:
        _validate_remote_arguments(mode, payload_arguments)
        if mode == "node":
            node_id, role, remote_root, cidr, api_port, distributed_port = (
                payload_arguments
            )
            payload = collect_node_probe(
                node_id=node_id,
                role=role,
                remote_root=remote_root,
                ipv4_cidr=cidr,
                api_port=int(api_port),
                distributed_port=int(distributed_port),
            )
        else:
            node_id = payload_arguments[0]
            targets = [_parse_target(value) for value in payload_arguments[1:]]
            payload = {
                "id": node_id,
                "reachable_node_ids": probe_reachability(node_id, targets),
            }
    except (TypeError, ValueError):
        print("node_probe: invalid remote probe invocation", file=sys.stderr)
        return 2
    print(json.dumps(payload, ensure_ascii=True, separators=(",", ":")))
    return 0


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="node_probe.py")
    subparsers = parser.add_subparsers(dest="command", required=True)

    run_ssh_parser = subparsers.add_parser("run-ssh")
    run_ssh_parser.add_argument("--timeout-seconds", required=True, type=float)
    run_ssh_parser.add_argument("argv", nargs=argparse.REMAINDER)

    encode_parser = subparsers.add_parser("encode")
    encode_parser.add_argument(
        "--mode",
        required=True,
        choices=("node", "reachability"),
    )
    encode_parser.add_argument("arguments", nargs=argparse.REMAINDER)

    remote_parser = subparsers.add_parser("remote")
    remote_parser.add_argument(
        "--mode",
        required=True,
        choices=("node", "reachability"),
    )
    remote_parser.add_argument("arguments", nargs=argparse.REMAINDER)
    return parser


def main(arguments: list[str] | None = None) -> int:
    parser = _build_parser()
    options = parser.parse_args(arguments)
    if options.command == "run-ssh":
        return _run_ssh_command(options.timeout_seconds, options.argv)
    if options.command == "encode":
        return _encode_remote_command(options.mode, options.arguments)
    if options.command == "remote":
        return _run_remote(options.mode, options.arguments)
    parser.error(f"unsupported command: {options.command}")
    return 2


if __name__ == "__main__":
    sys.exit(main())
