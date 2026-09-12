import hashlib
import json
import os
import pathlib
import tempfile
import unittest

from tools.artifact_manifest import (
    ArtifactManifest,
    ManifestError,
    ManifestFile,
    build_manifest,
    canonical_manifest_bytes,
    load_manifest,
    verify_manifest,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
VALID_MANIFEST = ROOT / "tests" / "fixtures" / "manifest.valid.json"


class ArtifactManifestTests(unittest.TestCase):
    def test_build_is_sorted_and_canonical(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "zeta.txt").write_bytes(b"zeta\n")
            (root / "nested").mkdir()
            (root / "nested" / "alpha.txt").write_bytes(b"alpha\n")

            manifest = build_manifest(root)

        self.assertEqual(
            [entry.path for entry in manifest.files],
            ["nested/alpha.txt", "zeta.txt"],
        )
        encoded = canonical_manifest_bytes(manifest)
        self.assertEqual(encoded, encoded.strip() + b"\n")
        self.assertEqual(
            json.loads(encoded),
            {
                "version": 1,
                "files": [
                    {
                        "path": "nested/alpha.txt",
                        "size": 6,
                        "sha256": hashlib.sha256(b"alpha\n").hexdigest(),
                    },
                    {
                        "path": "zeta.txt",
                        "size": 5,
                        "sha256": hashlib.sha256(b"zeta\n").hexdigest(),
                    },
                ],
            },
        )

    def test_build_rejects_symlinks(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            outside = root.parent / "outside.txt"
            outside.write_bytes(b"outside")
            (root / "escape").symlink_to(outside)

            with self.assertRaisesRegex(ManifestError, "symlink"):
                build_manifest(root)

    @unittest.skipUnless(hasattr(os, "mkfifo"), "FIFO requires os.mkfifo")
    def test_build_rejects_non_regular_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            os.mkfifo(root / "pipe")

            with self.assertRaisesRegex(ManifestError, "regular"):
                build_manifest(root)

    def test_verify_reports_digest_size_missing_and_unexpected_files(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "alpha.txt").write_bytes(b"changed")
            (root / "extra.txt").write_bytes(b"extra")
            manifest = load_manifest(VALID_MANIFEST)

            findings = verify_manifest(root, manifest)

        self.assertEqual(
            [(finding.path, finding.code) for finding in findings],
            [
                ("alpha.txt", "size_mismatch"),
                ("alpha.txt", "digest_mismatch"),
                ("nested/bravo.txt", "missing"),
                ("extra.txt", "unexpected"),
            ],
        )

    def test_verify_rejects_unsafe_manifest_paths_without_reading_outside(self) -> None:
        manifest = ArtifactManifest(
            version=1,
            files=(
                ManifestFile(
                    path="../outside",
                    size=1,
                    sha256=hashlib.sha256(b"x").hexdigest(),
                ),
            ),
        )
        with tempfile.TemporaryDirectory() as directory:
            findings = verify_manifest(pathlib.Path(directory), manifest)

        self.assertEqual(
            [(finding.path, finding.code) for finding in findings],
            [("../outside", "unsafe_path")],
        )

    def test_load_rejects_duplicate_unsorted_and_unknown_manifest_data(self) -> None:
        invalid_values = (
            {
                "version": 1,
                "files": [
                    {"path": "b", "size": 0, "sha256": "a" * 64},
                    {"path": "a", "size": 0, "sha256": "b" * 64},
                ],
            },
            {
                "version": 1,
                "files": [
                    {"path": "a", "size": 0, "sha256": "a" * 64},
                    {"path": "a", "size": 0, "sha256": "a" * 64},
                ],
            },
            {
                "version": 1,
                "files": [
                    {
                        "path": "a",
                        "size": 0,
                        "sha256": "a" * 64,
                        "unknown": True,
                    }
                ],
            },
        )
        for value in invalid_values:
            with self.subTest(value=value), tempfile.TemporaryDirectory() as directory:
                path = pathlib.Path(directory) / "manifest.json"
                path.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaises(ManifestError):
                    load_manifest(path)


if __name__ == "__main__":
    unittest.main()
