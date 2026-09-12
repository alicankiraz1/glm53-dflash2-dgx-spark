import json
import pathlib
import unittest

from tools.fabric_probe import Finding, evaluate_fabric, parse_probe


ROOT = pathlib.Path(__file__).resolve().parents[1]
FIXTURES = ROOT / "tests" / "fixtures" / "fabric"


class FabricProbeTests(unittest.TestCase):
    def load_fixture(self, name: str):
        return parse_probe((FIXTURES / name).read_text(encoding="utf-8"))

    def test_finding_json_is_stable_and_contains_no_remote_output(self) -> None:
        finding = Finding(
            id="node.node-a.identity",
            ok=True,
            summary="remote identity matches",
        )

        self.assertEqual(
            finding.to_json(),
            {
                "id": "node.node-a.identity",
                "ok": True,
                "summary": "remote identity matches",
            },
        )

    def test_healthy_fixture_passes_all_requirements_and_six_pairs(self) -> None:
        snapshot = self.load_fixture("healthy.json")

        findings = evaluate_fabric(snapshot)
        pair_findings = [
            finding for finding in findings if finding.id.startswith("fabric.pair.")
        ]

        self.assertEqual(len(snapshot.nodes), 4)
        self.assertTrue(all(finding.ok for finding in findings))
        self.assertEqual(
            [finding.id for finding in pair_findings],
            [
                "fabric.pair.node-a.node-b",
                "fabric.pair.node-a.node-c",
                "fabric.pair.node-a.node-d",
                "fabric.pair.node-b.node-c",
                "fabric.pair.node-b.node-d",
                "fabric.pair.node-c.node-d",
            ],
        )
        for node_id in ("node-a", "node-b", "node-c", "node-d"):
            node_checks = {
                finding.id
                for finding in findings
                if finding.id.startswith(f"node.{node_id}.")
            }
            self.assertTrue(
                {
                    f"node.{node_id}.ssh",
                    f"node.{node_id}.identity",
                    f"node.{node_id}.architecture",
                    f"node.{node_id}.gpu",
                    f"node.{node_id}.storage",
                    f"node.{node_id}.docker",
                    f"node.{node_id}.cdi",
                    f"node.{node_id}.api_port",
                    f"node.{node_id}.distributed_port",
                    f"node.{node_id}.fabric_tuple",
                    f"node.{node_id}.rdma",
                }.issubset(node_checks)
            )
        self.assertIn(
            "node.node-a.egress",
            {finding.id for finding in findings},
        )

    def test_missing_direction_fails_the_unordered_pair(self) -> None:
        snapshot = self.load_fixture("missing-link.json")

        failed = [finding for finding in evaluate_fabric(snapshot) if not finding.ok]

        self.assertEqual(
            [finding.id for finding in failed],
            ["fabric.pair.node-c.node-d"],
        )
        self.assertEqual(failed[0].summary, "bidirectional fabric path unavailable")

    def test_in_cidr_but_wrong_configured_fabric_address_fails(self) -> None:
        payload = json.loads(
            (FIXTURES / "healthy.json").read_text(encoding="utf-8")
        )
        payload["nodes"][0]["fabric"]["ipv4"] = "192.0.2.99"

        failed = [
            finding
            for finding in evaluate_fabric(parse_probe(json.dumps(payload)))
            if not finding.ok
        ]

        self.assertIn("node.node-a.fabric_tuple", {finding.id for finding in failed})

    def test_rejects_duplicate_nodes_and_unknown_fields(self) -> None:
        payload = json.loads(
            (FIXTURES / "healthy.json").read_text(encoding="utf-8")
        )
        payload["nodes"][1]["id"] = payload["nodes"][0]["id"]
        with self.assertRaisesRegex(ValueError, "duplicate"):
            parse_probe(json.dumps(payload))

        payload = json.loads(
            (FIXTURES / "healthy.json").read_text(encoding="utf-8")
        )
        payload["nodes"][0]["remote_stdout"] = "must not be exposed"
        with self.assertRaisesRegex(ValueError, "unknown"):
            parse_probe(json.dumps(payload))

    def test_failed_findings_do_not_echo_remote_values(self) -> None:
        payload = json.loads(
            (FIXTURES / "healthy.json").read_text(encoding="utf-8")
        )
        secret_marker = "REMOTE-SENSITIVE-MARKER"
        payload["nodes"][0]["gpu_name"] = secret_marker

        findings = evaluate_fabric(parse_probe(json.dumps(payload)))
        rendered = json.dumps([finding.to_json() for finding in findings])

        self.assertNotIn(secret_marker, rendered)
        self.assertFalse(
            next(finding for finding in findings if finding.id == "node.node-a.gpu").ok
        )


if __name__ == "__main__":
    unittest.main()
