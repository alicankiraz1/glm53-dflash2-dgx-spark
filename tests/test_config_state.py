import dataclasses
import datetime
import hashlib
import json
import os
import pathlib
import stat
import tempfile
import unittest
from unittest import mock

from tools.config_state import (
    ConfigError,
    ReproductionLock,
    RunEvent,
    RunState,
    StateError,
    append_run_event,
    config_digest,
    load_cluster,
    load_reproduction_lock,
    lock_digest,
    new_run_id,
    record_rank_container_id,
    read_run_events,
    read_run_state,
    write_run_state,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures"
VALID_CLUSTER = FIXTURES / "cluster.valid.json"
INVALID_THREE_NODES = FIXTURES / "cluster.invalid-three-nodes.json"
VALID_LOCK = ROOT / "config" / "reproduction.lock.json"
CLUSTER_SCHEMA = ROOT / "config" / "cluster.schema.json"
CLUSTER_EXAMPLE = ROOT / "config" / "cluster.example.json"


def write_json(path: pathlib.Path, value: object) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


def reverse_object_keys(value: object) -> object:
    if isinstance(value, dict):
        return {
            key: reverse_object_keys(child)
            for key, child in reversed(tuple(value.items()))
        }
    if isinstance(value, list):
        return [reverse_object_keys(child) for child in value]
    return value


class ClusterConfigTests(unittest.TestCase):
    def assert_cluster_rejected(
        self,
        value: object,
        message_pattern: str,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            write_json(path, value)
            with self.assertRaisesRegex(ConfigError, message_pattern):
                load_cluster(path)

    def test_loads_valid_ordered_four_node_cluster(self) -> None:
        cluster = load_cluster(VALID_CLUSTER)

        self.assertEqual(cluster.version, 1)
        self.assertEqual([node.rank for node in cluster.nodes], [0, 1, 2, 3])
        self.assertEqual([node.role for node in cluster.nodes].count("source"), 1)
        self.assertEqual(cluster.ssh.known_hosts_file, "~/.ssh/glm53_known_hosts")
        self.assertEqual(
            cluster.ssh.fabric_known_hosts_file,
            "/srv/glm53-operator/fabric_known_hosts",
        )
        self.assertEqual(cluster.ssh.connect_timeout_seconds, 7)
        self.assertEqual(cluster.ssh.command_timeout_seconds, 30)
        self.assertEqual(cluster.fabric.ipv4_cidr, "192.0.2.0/24")
        self.assertTrue(cluster.fabric.require_rdma)
        self.assertEqual(cluster.nodes[0].fabric_ipv4, "192.0.2.10")
        self.assertEqual(cluster.nodes[0].hf_cache_root, "/srv/hf-cache")
        self.assertEqual(
            cluster.nodes[0].expected_machine_id_sha256,
            "a" * 64,
        )
        self.assertEqual(cluster.ports.api, 8002)
        self.assertEqual(cluster.ports.distributed, 29600)

    def test_rejects_three_node_cluster(self) -> None:
        with self.assertRaisesRegex(ConfigError, "exactly four"):
            load_cluster(INVALID_THREE_NODES)

    def test_rejects_duplicate_rank(self) -> None:
        value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        value["nodes"][2]["rank"] = 1

        self.assert_cluster_rejected(value, "ranks")

    def test_rejects_duplicate_logical_ids(self) -> None:
        value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        value["nodes"][2]["id"] = value["nodes"][1]["id"]

        self.assert_cluster_rejected(value, "logical IDs")

    def test_rejects_duplicate_ssh_aliases(self) -> None:
        value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        value["nodes"][3]["ssh_alias"] = value["nodes"][0]["ssh_alias"]

        self.assert_cluster_rejected(value, "SSH aliases")

    def test_rejects_zero_source_roles(self) -> None:
        value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        value["nodes"][0]["role"] = "worker"

        self.assert_cluster_rejected(value, "exactly one source")

    def test_rejects_multiple_source_roles(self) -> None:
        value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        value["nodes"][1]["role"] = "source"

        self.assert_cluster_rejected(value, "exactly one source")

    def test_rejects_equal_api_and_distributed_ports(self) -> None:
        value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        value["ports"]["distributed"] = value["ports"]["api"]

        self.assert_cluster_rejected(value, "must be distinct")

    def test_rejects_credential_keys_before_unknown_key_validation(self) -> None:
        credential_keys = (
            "api_token",
            "ssh_key",
            "keyfile",
            "identity_file",
            "passphrase",
            "auth",
            "bearer",
            "pat",
            "cert",
        )
        for credential_key in credential_keys:
            with self.subTest(credential_key=credential_key):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                value["nodes"][0][credential_key] = "synthetic-value"
                self.assert_cluster_rejected(value, "credential")

    def test_allows_credential_words_in_alias_and_path_values(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            value["nodes"][3]["ssh_alias"] = "auth-cert-worker"
            value["nodes"][3]["remote_root"] = "/srv/ssh-key-artifacts"
            write_json(path, value)

            cluster = load_cluster(path)

        self.assertEqual(cluster.nodes[3].ssh_alias, "auth-cert-worker")
        self.assertEqual(cluster.nodes[3].remote_root, "/srv/ssh-key-artifacts")

    def test_rejects_unknown_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            value["unexpected"] = True
            write_json(path, value)

            with self.assertRaisesRegex(ConfigError, "unknown"):
                load_cluster(path)

    def test_rejects_empty_or_control_character_known_hosts_paths(self) -> None:
        invalid_paths = ("", "   ", "/tmp/known\nhosts", "/tmp/known\x7fhosts")
        for invalid_path in invalid_paths:
            with self.subTest(invalid_path=repr(invalid_path)):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                value["ssh"]["known_hosts_file"] = invalid_path
                self.assert_cluster_rejected(value, "known_hosts_file")

    def test_rejects_invalid_ssh_timeouts(self) -> None:
        invalid_values = (
            ("connect_timeout_seconds", 0),
            ("connect_timeout_seconds", True),
            ("connect_timeout_seconds", 601),
            ("command_timeout_seconds", 0),
            ("command_timeout_seconds", 3601),
        )
        for field, invalid_value in invalid_values:
            with self.subTest(field=field, invalid_value=invalid_value):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                value["ssh"][field] = invalid_value
                self.assert_cluster_rejected(value, field)

    def test_rejects_invalid_fabric_requirements(self) -> None:
        invalid_values = (
            ("ipv4_cidr", "192.0.2.12/24"),
            ("ipv4_cidr", "not-a-cidr"),
            ("ipv4_cidr", "2001:db8::/64"),
            ("require_rdma", False),
            ("require_rdma", 1),
        )
        for field, invalid_value in invalid_values:
            with self.subTest(field=field, invalid_value=invalid_value):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                value["fabric"][field] = invalid_value
                self.assert_cluster_rejected(value, field)

    def test_rejects_duplicate_or_out_of_cidr_node_fabric_addresses(self) -> None:
        values = []
        duplicate = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        duplicate["nodes"][2]["fabric_ipv4"] = duplicate["nodes"][1]["fabric_ipv4"]
        values.append(duplicate)
        outside = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
        outside["nodes"][2]["fabric_ipv4"] = "198.51.100.12"
        values.append(outside)

        for value in values:
            with self.subTest(value=value):
                self.assert_cluster_rejected(value, "fabric")

    def test_rejects_malformed_machine_identity_digest(self) -> None:
        invalid_digests = ("a" * 63, "A" * 64, "g" * 64)
        for invalid_digest in invalid_digests:
            with self.subTest(invalid_digest=invalid_digest):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                value["nodes"][0]["expected_machine_id_sha256"] = invalid_digest
                self.assert_cluster_rejected(
                    value,
                    "expected_machine_id_sha256",
                )

    def test_rejects_relative_remote_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            value["nodes"][0]["remote_root"] = "srv/glm53"
            write_json(path, value)

            with self.assertRaisesRegex(ConfigError, "absolute"):
                load_cluster(path)

    def test_rejects_relative_cache_and_fabric_known_hosts_paths(self) -> None:
        mutations = (
            (("nodes", 0, "hf_cache_root"), "var/cache/huggingface"),
            (("ssh", "fabric_known_hosts_file"), "~/.ssh/fabric_known_hosts"),
        )
        for path_parts, invalid_value in mutations:
            with self.subTest(path_parts=path_parts):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                current = value
                for key in path_parts[:-1]:
                    current = current[key]
                current[path_parts[-1]] = invalid_value
                self.assert_cluster_rejected(value, "absolute")

    def test_rejects_fabric_known_hosts_path_with_shell_metacharacters(self) -> None:
        for invalid_path in ("/srv/known hosts", "/srv/known;hosts", "/srv/known$hosts"):
            with self.subTest(invalid_path=invalid_path):
                value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                value["ssh"]["fabric_known_hosts_file"] = invalid_path
                self.assert_cluster_rejected(value, "safe absolute")

    def test_rejects_node_paths_with_shell_or_rsync_metacharacters(self) -> None:
        invalid_paths = (
            "/srv/glm53 package",
            "/srv/glm53;package",
            "/srv/glm53$package",
            "/srv/glm53`package`",
            "/srv/glm53|package",
            "/srv/glm53&package",
            "/srv/glm53*package",
            "/srv/glm53?package",
            "/srv/glm53[package]",
            "/srv/glm53\\package",
            "/srv/glm53'package'",
            '/srv/glm53"package"',
            "/srv/glm53:package",
            "/srv/glm53\tpackage",
            "/srv/glm53\npackage",
            "/srv/glm53(package)",
            "/srv/glm53>package",
            "/srv/glm53#package",
            "/srv/glm53~package",
            "/srv/glm53=package",
            "/srv/glm53,package",
            "/srv/glm53%package",
            "/srv/glm53!package",
            "/srv/glm53{package}",
        )
        for field in ("remote_root", "hf_cache_root"):
            for invalid_path in invalid_paths:
                with self.subTest(field=field, invalid_path=repr(invalid_path)):
                    value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
                    value["nodes"][0][field] = invalid_path
                    self.assert_cluster_rejected(value, "safe absolute")

    def test_accepts_safe_node_paths(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            value["nodes"][0]["remote_root"] = "/srv/glm53-package_v1.0/pkg"
            value["nodes"][0]["hf_cache_root"] = "/srv/hf-cache_v1.0/models"
            write_json(path, value)

            cluster = load_cluster(path)

        self.assertEqual(cluster.nodes[0].remote_root, "/srv/glm53-package_v1.0/pkg")
        self.assertEqual(
            cluster.nodes[0].hf_cache_root,
            "/srv/hf-cache_v1.0/models",
        )

    def test_config_digest_is_deterministic(self) -> None:
        first = load_cluster(VALID_CLUSTER)
        second = load_cluster(VALID_CLUSTER)

        self.assertEqual(config_digest(first), config_digest(second))
        self.assertRegex(config_digest(first), r"\A[0-9a-f]{64}\Z")

    def test_different_validated_configs_have_different_digests(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            value["nodes"][3]["remote_root"] = "/srv/glm53-package-alt"
            write_json(path, value)

            first = load_cluster(VALID_CLUSTER)
            second = load_cluster(path)

        self.assertNotEqual(config_digest(first), config_digest(second))

    def test_reordered_config_object_keys_have_identical_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            write_json(path, reverse_object_keys(value))

            first = load_cluster(VALID_CLUSTER)
            reordered = load_cluster(path)

        self.assertEqual(config_digest(first), config_digest(reordered))

    def test_new_cluster_fields_participate_in_config_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "cluster.json"
            value = json.loads(VALID_CLUSTER.read_text(encoding="utf-8"))
            value["ssh"]["command_timeout_seconds"] = 31
            write_json(path, value)

            first = load_cluster(VALID_CLUSTER)
            second = load_cluster(path)

        self.assertNotEqual(config_digest(first), config_digest(second))


class ClusterSchemaTests(unittest.TestCase):
    def test_schema_covers_all_loader_required_fields(self) -> None:
        schema = json.loads(CLUSTER_SCHEMA.read_text(encoding="utf-8"))

        self.assertEqual(
            set(schema["required"]),
            {"version", "ssh", "fabric", "nodes", "ports"},
        )
        self.assertEqual(
            set(schema["properties"]["ssh"]["required"]),
            {
                "known_hosts_file",
                "fabric_known_hosts_file",
                "connect_timeout_seconds",
                "command_timeout_seconds",
            },
        )
        self.assertEqual(
            set(schema["properties"]["fabric"]["required"]),
            {"ipv4_cidr", "require_rdma"},
        )
        self.assertIn(
            "expected_machine_id_sha256",
            schema["$defs"]["node"]["required"],
        )
        self.assertIn("hf_cache_root", schema["$defs"]["node"]["required"])
        self.assertIn("fabric_ipv4", schema["$defs"]["node"]["required"])
        safe_path_pattern = schema["properties"]["ssh"]["properties"][
            "fabric_known_hosts_file"
        ]["pattern"]
        for field in ("remote_root", "hf_cache_root"):
            self.assertEqual(
                schema["$defs"]["node"]["properties"][field]["pattern"],
                safe_path_pattern,
            )
        self.assertEqual(
            schema["$defs"]["node"]["properties"][
                "expected_machine_id_sha256"
            ]["pattern"],
            "^[0-9a-f]{64}$",
        )
        self.assertTrue(
            schema["properties"]["fabric"]["properties"]["require_rdma"]["const"]
        )

    def test_documented_example_uses_the_validated_contract(self) -> None:
        cluster = load_cluster(CLUSTER_EXAMPLE)

        self.assertEqual(cluster.fabric.ipv4_cidr, "192.0.2.0/24")
        self.assertEqual(cluster.nodes[3].expected_machine_id_sha256, "d" * 64)
        self.assertEqual(cluster.nodes[3].fabric_ipv4, "192.0.2.13")
        self.assertEqual(cluster.nodes[3].hf_cache_root, "/srv/hf-cache")


class ReproductionLockTests(unittest.TestCase):
    def test_loads_exact_approved_reproduction_lock(self) -> None:
        lock = load_reproduction_lock(VALID_LOCK)

        self.assertIsInstance(lock, ReproductionLock)
        self.assertEqual(lock.target_model.repository, "LibertAIDAI/GLM-5.3-Flash-NVFP4")
        self.assertEqual(lock.target_model.shards, 120)
        self.assertEqual(lock.target_model.tensor_bytes, 194644803576)
        self.assertEqual(lock.target_model.hub_bytes, 194692696910)
        self.assertEqual(lock.draft_model.shards, 1)
        self.assertEqual(lock.draft_model.tensor_bytes, 2342169800)
        self.assertEqual(lock.profile.context_length, 131072)
        self.assertEqual(lock.profile.max_running_requests, 4)
        self.assertEqual(lock.profile.speculative_algorithm, "DFLASH")
        self.assertEqual(lock.profile.speculative_num_draft_tokens, 8)
        self.assertEqual(lock.profile.api_port_default, 8002)
        self.assertEqual(lock.profile.dist_port_default, 29600)
        self.assertEqual(lock.profile.profile_name, "dflash-c4-128k-noradix")
        self.assertEqual(lock.profile.nnodes, 4)
        self.assertEqual(lock.profile.pp_size, 1)
        self.assertEqual(lock.profile.mem_fraction_static, 0.85)
        self.assertEqual(lock.profile.chunked_prefill_size, 8192)
        self.assertEqual(lock.profile.max_mamba_cache_size, 20)
        self.assertFalse(lock.profile.enable_shared_experts_fusion)
        self.assertEqual(lock.profile.sampling_defaults, "model")

    def test_lock_tracks_every_prepare_artifact_by_path_and_digest(self) -> None:
        lock = load_reproduction_lock(VALID_LOCK)
        tracked = (
            (lock.target_model.manifest_path, lock.target_model.manifest_sha256),
            (lock.draft_model.manifest_path, lock.draft_model.manifest_sha256),
            (
                lock.runtime.containerfile_path,
                lock.runtime.containerfile_sha256,
            ),
            (
                lock.runtime.patch_series_path,
                lock.runtime.patch_series_sha256,
            ),
            (
                "runtime/patches/sglang-glm53-gb10-tilelang.patch",
                lock.runtime.tilelang_patch_sha256,
            ),
        )

        for relative_path, expected_digest in tracked:
            with self.subTest(relative_path=relative_path):
                artifact_path = ROOT / relative_path
                self.assertTrue(artifact_path.is_file())
                self.assertEqual(
                    hashlib.sha256(artifact_path.read_bytes()).hexdigest(),
                    expected_digest,
                )

        self.assertEqual(lock.runtime.image_repository, "glm53-dflash2-dgx-spark")
        self.assertEqual(lock.runtime.image_owner, "glm53-spark")

    def test_rejects_changed_validated_profile(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "lock.json"
            value = json.loads(VALID_LOCK.read_text(encoding="utf-8"))
            value["profile"]["context_length"] = 262144
            write_json(path, value)

            with self.assertRaisesRegex(ConfigError, "approved reproduction lock"):
                load_reproduction_lock(path)

    def test_lock_digest_is_deterministic(self) -> None:
        first = load_reproduction_lock(VALID_LOCK)
        second = load_reproduction_lock(VALID_LOCK)

        self.assertEqual(lock_digest(first), lock_digest(second))
        self.assertRegex(lock_digest(first), r"\A[0-9a-f]{64}\Z")

    def test_different_lock_values_have_different_digests(self) -> None:
        first = load_reproduction_lock(VALID_LOCK)
        changed_profile = dataclasses.replace(
            first.profile,
            mem_fraction_static=0.84,
        )
        second = dataclasses.replace(first, profile=changed_profile)

        self.assertNotEqual(lock_digest(first), lock_digest(second))

    def test_reordered_lock_object_keys_have_identical_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "lock.json"
            value = json.loads(VALID_LOCK.read_text(encoding="utf-8"))
            write_json(path, reverse_object_keys(value))

            first = load_reproduction_lock(VALID_LOCK)
            reordered = load_reproduction_lock(path)

        self.assertEqual(lock_digest(first), lock_digest(reordered))


class RunStateTests(unittest.TestCase):
    def make_state(self, status: str = "planned") -> RunState:
        return RunState(
            version=1,
            run_id="20260828T091011.123456Z-00112233445566778899aabbccddeeff",
            config_digest="a" * 64,
            lock_digest="b" * 64,
            created_at="2026-08-28T09:10:11.123456Z",
            status=status,
            data={"ordered_node_ids": ["node-a", "node-b", "node-c", "node-d"]},
        )

    def test_new_run_id_is_deterministic_and_path_safe(self) -> None:
        now = datetime.datetime(
            2026,
            8,
            28,
            9,
            10,
            11,
            123456,
            tzinfo=datetime.timezone.utc,
        )

        run_id = new_run_id(now, bytes.fromhex("00112233445566778899aabbccddeeff"))

        self.assertEqual(
            run_id,
            "20260828T091011.123456Z-00112233445566778899aabbccddeeff",
        )
        self.assertNotIn("/", run_id)

    def test_write_uses_fsync_same_directory_replace_and_restrictive_modes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"
            state = self.make_state()
            replace_calls = []
            fsync_calls = []
            real_replace = os.replace
            real_fsync = os.fsync

            def recording_replace(source: object, destination: object) -> None:
                replace_calls.append((pathlib.Path(source), pathlib.Path(destination)))
                real_replace(source, destination)

            def recording_fsync(file_descriptor: int) -> None:
                fsync_calls.append(file_descriptor)
                real_fsync(file_descriptor)

            with mock.patch(
                "tools.config_state.os.replace",
                side_effect=recording_replace,
            ), mock.patch(
                "tools.config_state.os.fsync",
                side_effect=recording_fsync,
            ):
                state_path = write_run_state(state_root, state)

            self.assertEqual(state_path, state_root / "runs" / state.run_id / "run.json")
            self.assertGreaterEqual(len(fsync_calls), 2)
            self.assertEqual(len(replace_calls), 1)
            temporary_path, destination_path = replace_calls[0]
            self.assertEqual(temporary_path.parent, destination_path.parent)
            self.assertEqual(destination_path, state_path)
            self.assertFalse(temporary_path.exists())
            self.assertEqual(stat.S_IMODE(state_path.stat().st_mode), 0o600)
            self.assertEqual(stat.S_IMODE(state_path.parent.stat().st_mode), 0o700)
            self.assertEqual(read_run_state(state_root, state.run_id), state)

    def test_atomic_replacement_returns_latest_complete_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"
            first = self.make_state("planned")
            second = self.make_state("ready")

            write_run_state(state_root, first)
            write_run_state(state_root, second)

            self.assertEqual(read_run_state(state_root, second.run_id), second)
            self.assertEqual(
                list((state_root / "runs" / second.run_id).glob(".run.json.*")),
                [],
            )

    def test_rejects_malformed_state(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"
            state = self.make_state()
            state_path = write_run_state(state_root, state)
            state_path.write_text('{"version": 1', encoding="utf-8")

            with self.assertRaisesRegex(StateError, "valid JSON"):
                read_run_state(state_root, state.run_id)

    def test_rejects_tampered_state_digest(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"
            state = self.make_state()
            state_path = write_run_state(state_root, state)
            value = json.loads(state_path.read_text(encoding="utf-8"))
            value["status"] = "tampered"
            write_json(state_path, value)

            with self.assertRaisesRegex(StateError, "record digest"):
                read_run_state(state_root, state.run_id)

    def test_rejects_credential_keys_in_run_state_data(self) -> None:
        credential_keys = (
            "api_token",
            "ssh_key",
            "keyfile",
            "identity_file",
            "passphrase",
            "auth",
            "bearer",
            "pat",
            "cert",
        )
        for credential_key in credential_keys:
            with self.subTest(credential_key=credential_key):
                state = dataclasses.replace(
                    self.make_state(),
                    data={credential_key: "synthetic-value"},
                )
                with tempfile.TemporaryDirectory() as directory:
                    with self.assertRaisesRegex(StateError, "credential"):
                        write_run_state(pathlib.Path(directory), state)

    def test_rejects_path_traversal_run_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(StateError, "run ID"):
                read_run_state(pathlib.Path(directory), "../outside")

    def test_rejects_symlinked_state_directory(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            temporary_root = pathlib.Path(directory)
            external_root = temporary_root / "external"
            state = self.make_state()
            write_run_state(external_root, state)
            state_root = temporary_root / "state"
            state_root.mkdir()
            (state_root / "runs").symlink_to(
                external_root / "runs",
                target_is_directory=True,
            )

            with self.assertRaisesRegex(StateError, "plain directory"):
                read_run_state(state_root, state.run_id)


class RankContainerIdentityTests(unittest.TestCase):
    RUN_ID = "20260828T091011.123456Z-00112233445566778899aabbccddeeff"

    def make_state(self, include_ids: bool = True) -> RunState:
        ranks = []
        for rank in range(4):
            record = {"rank": rank}
            if include_ids:
                record["container_id"] = ""
            ranks.append(record)
        return RunState(
            version=1,
            run_id=self.RUN_ID,
            config_digest="a" * 64,
            lock_digest="b" * 64,
            created_at="2026-08-28T09:10:11.123456Z",
            status="launching",
            data={"ranks": ranks},
        )

    def test_records_a_rank_id_once_and_rejects_rebinding(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"
            write_run_state(state_root, self.make_state())
            first_id = "c" * 64

            record_rank_container_id(state_root, self.RUN_ID, 2, first_id)
            record_rank_container_id(state_root, self.RUN_ID, 2, first_id)

            state = read_run_state(state_root, self.RUN_ID)
            self.assertEqual(state.data["ranks"][2]["container_id"], first_id)
            with self.assertRaisesRegex(StateError, "already bound"):
                record_rank_container_id(state_root, self.RUN_ID, 2, "d" * 64)

    def test_rejects_a_legacy_rank_record_without_container_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"
            write_run_state(state_root, self.make_state(include_ids=False))

            with self.assertRaisesRegex(StateError, "lacks immutable"):
                record_rank_container_id(state_root, self.RUN_ID, 0, "c" * 64)


class RunEventTests(unittest.TestCase):
    RUN_ID = "20260828T091011.123456Z-00112233445566778899aabbccddeeff"

    def make_state(self) -> RunState:
        return RunState(
            version=1,
            run_id=self.RUN_ID,
            config_digest="a" * 64,
            lock_digest="b" * 64,
            created_at="2026-08-28T09:10:11.123456Z",
            status="launching",
            data={"ranks": []},
        )

    def make_event(
        self,
        sequence: int,
        action: str = "stage",
        status: str = "succeeded",
    ) -> RunEvent:
        return RunEvent(
            sequence=sequence,
            recorded_at="2026-08-28T09:10:12.000000Z",
            phase="phase-one",
            action=action,
            status=status,
            detail={"node_id": "node-a"},
        )

    def prepared_root(self, directory: str) -> pathlib.Path:
        state_root = pathlib.Path(directory) / "state"
        write_run_state(state_root, self.make_state())
        return state_root

    def test_appends_events_in_order_and_reads_them_back(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = self.prepared_root(directory)

            append_run_event(state_root, self.RUN_ID, self.make_event(1))
            append_run_event(
                state_root,
                self.RUN_ID,
                self.make_event(2, action="release", status="failed"),
            )

            events = read_run_events(state_root, self.RUN_ID)

            self.assertEqual([event.sequence for event in events], [1, 2])
            self.assertEqual(events[1].action, "release")
            self.assertEqual(events[1].status, "failed")
            self.assertEqual(events[0].detail, {"node_id": "node-a"})

    def test_event_log_is_append_only_and_restrictive(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = self.prepared_root(directory)
            append_run_event(state_root, self.RUN_ID, self.make_event(1))
            events_path = state_root / "runs" / self.RUN_ID / "events.jsonl"
            first_bytes = events_path.read_bytes()

            append_run_event(state_root, self.RUN_ID, self.make_event(2))

            self.assertEqual(stat.S_IMODE(events_path.stat().st_mode), 0o600)
            self.assertTrue(events_path.read_bytes().startswith(first_bytes))
            self.assertEqual(
                len(events_path.read_text(encoding="utf-8").splitlines()),
                2,
            )

    def test_rejects_non_monotonic_sequence(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = self.prepared_root(directory)
            append_run_event(state_root, self.RUN_ID, self.make_event(1))

            for sequence in (1, 0, -1):
                with self.subTest(sequence=sequence):
                    with self.assertRaisesRegex(StateError, "sequence"):
                        append_run_event(
                            state_root,
                            self.RUN_ID,
                            self.make_event(sequence),
                        )

    def test_rejects_credential_keys_in_event_detail(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = self.prepared_root(directory)
            event = dataclasses.replace(
                self.make_event(1),
                detail={"api_token": "synthetic-value"},
            )

            with self.assertRaisesRegex(StateError, "credential"):
                append_run_event(state_root, self.RUN_ID, event)

    def test_rejects_malformed_event_fields(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = self.prepared_root(directory)
            malformed = (
                {"phase": "Phase One"},
                {"action": ""},
                {"status": "NOT-A-STATUS"},
                {"recorded_at": "2026-08-28T09:10:12.000000"},
            )
            for replacement in malformed:
                with self.subTest(replacement=replacement):
                    event = dataclasses.replace(self.make_event(1), **replacement)
                    with self.assertRaises(StateError):
                        append_run_event(state_root, self.RUN_ID, event)

    def test_rejects_event_for_unrecorded_run(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = pathlib.Path(directory) / "state"

            with self.assertRaises(StateError):
                append_run_event(state_root, self.RUN_ID, self.make_event(1))

    def test_rejects_path_traversal_run_id(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(StateError, "run ID"):
                append_run_event(
                    pathlib.Path(directory),
                    "../outside",
                    self.make_event(1),
                )

    def test_rejects_tampered_event_log(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            state_root = self.prepared_root(directory)
            append_run_event(state_root, self.RUN_ID, self.make_event(1))
            events_path = state_root / "runs" / self.RUN_ID / "events.jsonl"
            events_path.write_text('{"sequence": 1', encoding="utf-8")

            with self.assertRaises(StateError):
                read_run_events(state_root, self.RUN_ID)


if __name__ == "__main__":
    unittest.main()
