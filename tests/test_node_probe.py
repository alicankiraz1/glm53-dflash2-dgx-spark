import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest

from tools.node_probe import (
    SSH_EXIT_FAILED,
    SSH_EXIT_SPAWN_ERROR,
    SSH_EXIT_TIMEOUT,
    CommandResult,
    build_remote_command,
    join_rdma_link,
    machine_id_sha256,
    port_is_available,
    probe_reachability,
    run_ssh,
    select_fabric_interface,
    select_storage_ancestor,
    source_egress_available,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
NODE_PROBE = ROOT / "tools" / "node_probe.py"


class SSHRunnerTests(unittest.TestCase):
    def test_success_uses_devnull_and_bounded_subprocess_timeout(self) -> None:
        observed = {}

        def fake_runner(command, **kwargs):
            observed["command"] = command
            observed["kwargs"] = kwargs
            return subprocess.CompletedProcess(
                command,
                0,
                stdout='{"ok":true}\n',
                stderr="REMOTE-SENSITIVE-MARKER",
            )

        result = run_ssh(["ssh", "node-a", "fixed-command"], 7.5, fake_runner)

        self.assertEqual(result.exit_code, 0)
        self.assertEqual(result.stdout, '{"ok":true}\n')
        self.assertEqual(observed["command"], ["ssh", "node-a", "fixed-command"])
        self.assertEqual(observed["kwargs"]["stdin"], subprocess.DEVNULL)
        self.assertEqual(observed["kwargs"]["timeout"], 7.5)
        self.assertEqual(observed["kwargs"]["stderr"], subprocess.PIPE)
        self.assertNotIn("REMOTE-SENSITIVE-MARKER", result.stdout)

    def test_failure_timeout_and_spawn_error_have_stable_exit_mapping(self) -> None:
        def failed_runner(command, **kwargs):
            return subprocess.CompletedProcess(
                command,
                255,
                stdout="untrusted stdout",
                stderr="untrusted stderr",
            )

        def timeout_runner(command, **kwargs):
            raise subprocess.TimeoutExpired(command, kwargs["timeout"])

        def spawn_error_runner(command, **kwargs):
            raise OSError("sensitive local path")

        self.assertEqual(run_ssh(["ssh"], 1, failed_runner).exit_code, SSH_EXIT_FAILED)
        self.assertEqual(run_ssh(["ssh"], 1, timeout_runner).exit_code, SSH_EXIT_TIMEOUT)
        self.assertEqual(
            run_ssh(["ssh"], 1, spawn_error_runner).exit_code,
            SSH_EXIT_SPAWN_ERROR,
        )

    def test_cli_wall_clock_timeout_redacts_child_stderr(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            ssh = pathlib.Path(directory) / "ssh"
            ssh.write_text(
                "#!/bin/sh\n"
                "printf 'REMOTE-SENSITIVE-MARKER\\n' >&2\n"
                "sleep 2\n",
                encoding="utf-8",
            )
            ssh.chmod(0o700)

            result = subprocess.run(
                [
                    sys.executable,
                    str(NODE_PROBE),
                    "run-ssh",
                    "--timeout-seconds",
                    "0.05",
                    "--",
                    str(ssh),
                ],
                input="caller input",
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                timeout=1,
                check=False,
            )

        self.assertEqual(result.returncode, SSH_EXIT_TIMEOUT)
        self.assertEqual(result.stdout, "")
        self.assertEqual(result.stderr, "node_probe: ssh command timed out\n")
        self.assertNotIn("REMOTE-SENSITIVE-MARKER", result.stderr)


class NodeProbeFunctionTests(unittest.TestCase):
    def test_machine_id_hashes_stripped_content(self) -> None:
        digest = machine_id_sha256(
            lambda path: " synthetic-machine-id \n",
        )

        self.assertEqual(
            digest,
            hashlib.sha256(b"synthetic-machine-id").hexdigest(),
        )

    def test_storage_selects_nearest_existing_ancestor(self) -> None:
        existing = {pathlib.Path("/"), pathlib.Path("/srv")}

        selected = select_storage_ancestor(
            pathlib.Path("/srv/glm53/artifacts"),
            lambda path: path in existing,
        )

        self.assertEqual(selected, pathlib.Path("/srv"))

    def test_port_state_requires_success_and_no_listener(self) -> None:
        commands = []

        def available(command, timeout_seconds):
            commands.append((command, timeout_seconds))
            return CommandResult(0, "")

        def occupied(command, timeout_seconds):
            return CommandResult(0, "LISTEN 0 4096 *:8002")

        def unavailable(command, timeout_seconds):
            return CommandResult(127, "")

        self.assertTrue(port_is_available(8002, available))
        self.assertFalse(port_is_available(8002, occupied))
        self.assertFalse(port_is_available(8002, unavailable))
        self.assertEqual(
            commands,
            [(["ss", "-H", "-ltn", "sport = :8002"], 10)],
        )

    def test_fabric_selection_uses_configured_cidr_and_active_interface(self) -> None:
        payload = json.dumps(
            [
                {
                    "ifname": "eth0",
                    "addr_info": [{"local": "198.51.100.8"}],
                },
                {
                    "ifname": "fabric0",
                    "addr_info": [
                        {"local": "192.0.2.0"},
                        {"local": "192.0.2.12"},
                    ],
                },
            ]
        )

        self.assertEqual(
            select_fabric_interface("192.0.2.0/24", payload),
            ("fabric0", "192.0.2.12"),
        )

    def test_rdma_join_matches_the_selected_netdev(self) -> None:
        payload = json.dumps(
            [
                {
                    "netdev": "eth0",
                    "ifname": "roce-other",
                    "state": "ACTIVE",
                },
                {
                    "netdev": "fabric0",
                    "ifname": "roce0",
                    "state": "ACTIVE",
                },
            ]
        )

        self.assertEqual(
            join_rdma_link("fabric0", payload),
            ("roce0", "ACTIVE"),
        )

    def test_source_egress_is_role_gated_and_closes_connection(self) -> None:
        calls = []

        class FakeConnection:
            def close(self):
                calls.append("closed")

        def connector(address, timeout):
            calls.append((address, timeout))
            return FakeConnection()

        self.assertFalse(source_egress_available("worker", connector))
        self.assertEqual(calls, [])
        self.assertTrue(source_egress_available("source", connector))
        self.assertEqual(
            calls,
            [(("huggingface.co", 443), 5), "closed"],
        )

    def test_reachability_uses_fixed_ping_and_reports_only_successes(self) -> None:
        commands = []

        def runner(command, timeout_seconds):
            commands.append((command, timeout_seconds))
            return CommandResult(0 if command[-1] == "192.0.2.12" else 1, "")

        reachable = probe_reachability(
            "node-a",
            [
                ("node-a", "192.0.2.11"),
                ("node-b", "192.0.2.12"),
                ("node-c", "192.0.2.13"),
            ],
            runner,
        )

        self.assertEqual(reachable, ["node-b"])
        self.assertEqual(
            commands,
            [
                (["ping", "-c", "1", "-W", "2", "192.0.2.12"], 5),
                (["ping", "-c", "1", "-W", "2", "192.0.2.13"], 5),
            ],
        )

    def test_remote_command_uses_real_mode_without_test_marker(self) -> None:
        source = b"print('reviewed source')\n"

        command = build_remote_command(
            source,
            "reachability",
            ["node-a", "node-b=192.0.2.12"],
        )

        self.assertIn("--mode reachability", command)
        self.assertNotIn("GLM53_REACHABILITY_PROBE", command)
        self.assertNotIn("reviewed source", command)


if __name__ == "__main__":
    unittest.main()
