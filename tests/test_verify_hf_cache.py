import hashlib
import json
import pathlib
import tempfile
import unittest

from tools.verify_hf_cache import (
    ARTIFACT_MANIFEST_KIND,
    HUB_MANIFEST_KIND,
    CacheVerificationError,
    load_snapshot_manifest,
    verify_hf_cache,
    verify_snapshot,
)


REVISION = "a" * 40


def write_json(path: pathlib.Path, value: object) -> None:
    path.write_text(json.dumps(value, sort_keys=True) + "\n", encoding="utf-8")


def git_blob_digest(payload: bytes) -> str:
    hasher = hashlib.sha1()
    hasher.update(f"blob {len(payload)}\0".encode("ascii"))
    hasher.update(payload)
    return hasher.hexdigest()


def build_single_shard_snapshot(
    root: pathlib.Path,
    weights: bytes = b"weights",
    config: bytes = b'{"model_type":"glm"}',
) -> pathlib.Path:
    """Create a realistic single-shard Hugging Face cache repository."""
    repo_root = root / "models--example--model"
    blob_root = repo_root / "blobs"
    snapshot_root = repo_root / "snapshots" / REVISION
    blob_root.mkdir(parents=True)
    snapshot_root.mkdir(parents=True)
    weights_digest = hashlib.sha256(weights).hexdigest()
    (blob_root / weights_digest).write_bytes(weights)
    config_digest = git_blob_digest(config)
    (blob_root / config_digest).write_bytes(config)
    (snapshot_root / "model.safetensors").symlink_to(
        pathlib.Path("..") / ".." / "blobs" / weights_digest
    )
    (snapshot_root / "config.json").symlink_to(
        pathlib.Path("..") / ".." / "blobs" / config_digest
    )
    return snapshot_root


def hub_manifest_value(
    weights: bytes = b"weights",
    config: bytes = b'{"model_type":"glm"}',
) -> dict[str, object]:
    return {
        "revision": REVISION,
        "files": {
            "model.safetensors": hashlib.sha256(weights).hexdigest(),
            "config.json": git_blob_digest(config),
        },
    }


def artifact_manifest_value(
    weights: bytes = b"weights",
    config: bytes = b'{"model_type":"glm"}',
    weights_size: int | None = None,
) -> dict[str, object]:
    return {
        "version": 1,
        "repository": "example/model",
        "revision": REVISION,
        "files": [
            {
                "path": "config.json",
                "size": len(config),
                "sha256": git_blob_digest(config),
            },
            {
                "path": "model.safetensors",
                "size": len(weights) if weights_size is None else weights_size,
                "sha256": hashlib.sha256(weights).hexdigest(),
            },
        ],
    }


class HuggingFaceCacheVerifierTests(unittest.TestCase):
    def make_cache(
        self,
        root: pathlib.Path,
    ) -> tuple[pathlib.Path, pathlib.Path, pathlib.Path]:
        repository = "example/model"
        revision = "a" * 40
        repo_root = root / "models--example--model"
        blob_root = repo_root / "blobs"
        snapshot_root = repo_root / "snapshots" / revision
        blob_root.mkdir(parents=True)
        snapshot_root.mkdir(parents=True)
        payload = b"weights"
        blob_digest = hashlib.sha256(payload).hexdigest()
        blob = blob_root / blob_digest
        blob.write_bytes(payload)
        (snapshot_root / "model-00001-of-00001.safetensors").symlink_to(
            pathlib.Path("..") / ".." / "blobs" / blob_digest
        )
        manifest = root / "authoritative.json"
        write_json(
            manifest,
            {
                "version": 1,
                "repository": repository,
                "revision": revision,
                "files": [
                    {
                        "path": "model-00001-of-00001.safetensors",
                        "size": len(payload),
                        "sha256": blob_digest,
                    }
                ],
            },
        )
        return manifest, blob, snapshot_root

    def test_accepts_complete_snapshot_and_blob(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, _, _ = self.make_cache(root)

            findings = verify_hf_cache(root, manifest)

        self.assertEqual(findings, [])

    def test_reports_missing_tampered_and_unexpected_snapshot_files(self) -> None:
        scenarios = ("missing", "tampered", "unexpected")
        for scenario in scenarios:
            with self.subTest(scenario=scenario), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                manifest, blob, snapshot = self.make_cache(root)
                link = snapshot / "model-00001-of-00001.safetensors"
                if scenario == "missing":
                    link.unlink()
                elif scenario == "tampered":
                    blob.write_bytes(b"tampered")
                else:
                    (snapshot / "unexpected.json").write_text("{}", encoding="utf-8")

                findings = verify_hf_cache(root, manifest)

                self.assertTrue(findings)
                self.assertIn(scenario, {finding.code for finding in findings})

    def test_rejects_snapshot_links_outside_the_repository_blob_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            manifest, _, snapshot = self.make_cache(root)
            outside = root / "outside"
            outside.write_bytes(b"weights")
            link = snapshot / "model-00001-of-00001.safetensors"
            link.unlink()
            link.symlink_to(outside)

            with self.assertRaisesRegex(CacheVerificationError, "blob root"):
                verify_hf_cache(root, manifest)

    def test_rejects_duplicate_keys_and_path_traversal_in_manifest(self) -> None:
        invalid_documents = (
            (
                '{"version":1,"version":1,"repository":"example/model",'
                '"revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",'
                '"files":[]}'
            ),
            json.dumps(
                {
                    "version": 1,
                    "repository": "example/model",
                    "revision": "a" * 40,
                    "files": [
                        {
                            "path": "../escape",
                            "size": 0,
                            "sha256": "a" * 64,
                        }
                    ],
                }
            ),
        )
        for document in invalid_documents:
            with self.subTest(document=document), tempfile.TemporaryDirectory() as directory:
                root = pathlib.Path(directory)
                manifest = root / "manifest.json"
                manifest.write_text(document, encoding="utf-8")
                with self.assertRaises(CacheVerificationError):
                    verify_hf_cache(root, manifest)


class SnapshotManifestContractTests(unittest.TestCase):
    def test_hub_and_artifact_contracts_are_identified_separately(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            hub_path = root / "hub.json"
            artifact_path = root / "artifact.json"
            write_json(hub_path, hub_manifest_value())
            write_json(artifact_path, artifact_manifest_value())

            hub = load_snapshot_manifest(hub_path)
            artifact = load_snapshot_manifest(artifact_path)

        self.assertEqual(hub.kind, HUB_MANIFEST_KIND)
        self.assertIsNone(hub.repository)
        self.assertEqual(hub.revision, REVISION)
        self.assertTrue(all(entry.size is None for entry in hub.files.values()))
        self.assertEqual(artifact.kind, ARTIFACT_MANIFEST_KIND)
        self.assertEqual(artifact.repository, "example/model")
        self.assertTrue(all(entry.size is not None for entry in artifact.files.values()))

    def test_rejects_documents_that_match_neither_contract(self) -> None:
        invalid_values = (
            {"revision": REVISION},
            {"revision": REVISION, "files": {}, "version": 1},
            {"version": 1, "revision": REVISION, "files": []},
            {
                "version": 1,
                "repository": "example/model",
                "revision": REVISION,
                "files": [{"path": "a", "sha256": "a" * 64}],
            },
        )
        for value in invalid_values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "manifest.json"
                write_json(path, value)
                with self.assertRaises(CacheVerificationError):
                    load_snapshot_manifest(path)

    def test_tracked_production_manifests_use_the_hub_contract(self) -> None:
        root = pathlib.Path(__file__).resolve().parents[1] / "manifests"
        for manifest_path in sorted(root.glob("glm53-*.json")):
            with self.subTest(manifest=manifest_path.name):
                manifest = load_snapshot_manifest(manifest_path)

                self.assertEqual(manifest.kind, HUB_MANIFEST_KIND)
                self.assertTrue(manifest.files)


class SnapshotVerificationTests(unittest.TestCase):
    def verify(
        self,
        snapshot: pathlib.Path,
        manifest: pathlib.Path,
        verify_blobs: bool = True,
        total_size: int = len(b"weights"),
    ) -> dict[str, int | str]:
        return verify_snapshot(
            snapshot,
            REVISION,
            1,
            total_size,
            verify_blobs,
            manifest,
        )

    def test_hub_manifest_requires_blob_verification(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "hub.json"
            write_json(manifest, hub_manifest_value())

            with self.assertRaisesRegex(CacheVerificationError, "blob verification"):
                self.verify(snapshot, manifest, verify_blobs=False)

    def test_hub_manifest_verifies_every_file_by_content(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "hub.json"
            write_json(manifest, hub_manifest_value())

            result = self.verify(snapshot, manifest)

        self.assertEqual(result["manifest_kind"], HUB_MANIFEST_KIND)
        self.assertEqual(result["manifest_files"], 2)
        self.assertEqual(result["verified_blobs"], 2)
        self.assertEqual(result["size_checked_files"], 0)

    def test_artifact_manifest_enforces_declared_sizes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "artifact.json"
            write_json(manifest, artifact_manifest_value(weights_size=999))

            with self.assertRaisesRegex(CacheVerificationError, "size does not match"):
                self.verify(snapshot, manifest)

    def test_artifact_manifest_reports_size_coverage(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "artifact.json"
            write_json(manifest, artifact_manifest_value())

            result = self.verify(snapshot, manifest)

        self.assertEqual(result["manifest_kind"], ARTIFACT_MANIFEST_KIND)
        self.assertEqual(result["size_checked_files"], 2)

    def test_rejects_tampered_blob_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "hub.json"
            write_json(manifest, hub_manifest_value())
            blob = (snapshot / "model.safetensors").resolve()
            blob.write_bytes(b"tampere")

            with self.assertRaisesRegex(CacheVerificationError, "digest"):
                self.verify(snapshot, manifest)

    def test_rejects_declared_tensor_total_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "hub.json"
            write_json(manifest, hub_manifest_value())

            with self.assertRaisesRegex(CacheVerificationError, "tensor byte count"):
                self.verify(snapshot, manifest, total_size=999)

    def test_rejects_manifest_revision_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "hub.json"
            value = hub_manifest_value()
            value["revision"] = "b" * 40
            write_json(manifest, value)

            with self.assertRaisesRegex(CacheVerificationError, "revision"):
                self.verify(snapshot, manifest)

    def test_rejects_snapshot_file_set_drift(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            snapshot = build_single_shard_snapshot(root)
            manifest = root / "hub.json"
            write_json(manifest, hub_manifest_value())
            (snapshot / "extra.json").write_text("{}", encoding="utf-8")

            with self.assertRaisesRegex(CacheVerificationError, "file set"):
                self.verify(snapshot, manifest)


if __name__ == "__main__":
    unittest.main()
