import hashlib
import json
import pathlib
import tempfile
import unittest

from tools.patch_series import (
    PatchSeriesError,
    load_patch_series,
    main,
    verify_patch_series,
)


ROOT = pathlib.Path(__file__).resolve().parents[1]
PRODUCTION_SERIES = ROOT / "runtime" / "patches" / "series.json"
TWO_PATCH_SERIES = ROOT / "tests" / "fixtures" / "patches" / "series.two.json"
ALPHA_PATCH = ROOT / "tests" / "fixtures" / "patches" / "alpha.patch"
BRAVO_PATCH = ROOT / "tests" / "fixtures" / "patches" / "bravo.patch"


def digest_of(path: pathlib.Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class PatchSeriesLoadTests(unittest.TestCase):
    def assert_series_rejected(self, value: object, message_pattern: str) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "series.json"
            path.write_text(json.dumps(value), encoding="utf-8")
            with self.assertRaisesRegex(PatchSeriesError, message_pattern):
                load_patch_series(path)

    def test_loads_the_tracked_production_series(self) -> None:
        series = load_patch_series(PRODUCTION_SERIES)

        self.assertEqual(
            [entry.path for entry in series.patches],
            ["sglang-glm53-gb10-tilelang.patch"],
        )
        self.assertEqual(
            series.patches[0].sha256,
            digest_of(PRODUCTION_SERIES.parent / "sglang-glm53-gb10-tilelang.patch"),
        )

    def test_preserves_declared_order_instead_of_sorting(self) -> None:
        series = load_patch_series(TWO_PATCH_SERIES)

        self.assertEqual(
            [entry.path for entry in series.patches],
            ["bravo.patch", "alpha.patch"],
        )
        self.assertEqual(series.patches[0].sha256, digest_of(BRAVO_PATCH))
        self.assertEqual(series.patches[1].sha256, digest_of(ALPHA_PATCH))

    def test_rejects_paths_outside_the_series_directory(self) -> None:
        for unsafe_path in ("../outside.patch", "/etc/outside.patch", "./alpha.patch"):
            with self.subTest(unsafe_path=unsafe_path):
                self.assert_series_rejected(
                    {
                        "version": 1,
                        "patches": [{"path": unsafe_path, "sha256": "a" * 64}],
                    },
                    "contained relative path",
                )

    def test_rejects_invalid_schema(self) -> None:
        invalid_values = (
            {"version": 2, "patches": [{"path": "a.patch", "sha256": "a" * 64}]},
            {"version": 1, "patches": []},
            {"version": 1, "patches": {"path": "a.patch"}},
            {"version": 1},
            {
                "version": 1,
                "patches": [{"path": "a.patch", "sha256": "a" * 64}],
                "unknown": True,
            },
            {
                "version": 1,
                "patches": [{"path": "a.patch", "sha256": "a" * 64, "extra": 1}],
            },
            {"version": 1, "patches": [{"path": "a.patch", "sha256": "A" * 64}]},
            {"version": 1, "patches": [{"path": "a.patch", "sha256": "a" * 63}]},
            {
                "version": 1,
                "patches": [
                    {"path": "a.patch", "sha256": "a" * 64},
                    {"path": "a.patch", "sha256": "a" * 64},
                ],
            },
        )
        for value in invalid_values:
            with self.subTest(value=value):
                self.assert_series_rejected(value, "series")

    def test_rejects_duplicate_json_keys(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "series.json"
            path.write_text(
                '{"version":1,"version":1,"patches":[]}',
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PatchSeriesError, "duplicate"):
                load_patch_series(path)


class PatchSeriesVerifyTests(unittest.TestCase):
    def test_verifies_every_declared_patch_file(self) -> None:
        findings = verify_patch_series(TWO_PATCH_SERIES)

        self.assertEqual(findings, [])

    def test_reports_second_patch_digest_mismatch(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "bravo.patch").write_bytes(BRAVO_PATCH.read_bytes())
            (root / "alpha.patch").write_bytes(b"tampered\n")
            series = root / "series.json"
            series.write_bytes(TWO_PATCH_SERIES.read_bytes())

            findings = verify_patch_series(series)

        self.assertEqual(
            [(finding.path, finding.code) for finding in findings],
            [("alpha.patch", "digest_mismatch")],
        )

    def test_reports_missing_patch_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "bravo.patch").write_bytes(BRAVO_PATCH.read_bytes())
            series = root / "series.json"
            series.write_bytes(TWO_PATCH_SERIES.read_bytes())

            findings = verify_patch_series(series)

        self.assertEqual(
            [(finding.path, finding.code) for finding in findings],
            [("alpha.patch", "missing")],
        )

    def test_reports_symlinked_patch_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "bravo.patch").write_bytes(BRAVO_PATCH.read_bytes())
            (root / "alpha.patch").symlink_to(ALPHA_PATCH)
            series = root / "series.json"
            series.write_bytes(TWO_PATCH_SERIES.read_bytes())

            findings = verify_patch_series(series)

        self.assertEqual(
            [(finding.path, finding.code) for finding in findings],
            [("alpha.patch", "not_regular")],
        )


class PatchSeriesCommandTests(unittest.TestCase):
    def test_verify_prints_ordered_path_and_digest_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            output = pathlib.Path(directory) / "series.txt"
            with output.open("w", encoding="utf-8") as stream:
                status = main(["verify", "--series", str(TWO_PATCH_SERIES)], stream)
            records = output.read_text(encoding="utf-8")

        self.assertEqual(status, 0)
        self.assertEqual(
            records,
            f"bravo.patch\t{digest_of(BRAVO_PATCH)}\n"
            f"alpha.patch\t{digest_of(ALPHA_PATCH)}\n",
        )

    def test_verify_fails_closed_on_mismatch_without_printing_records(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / "bravo.patch").write_bytes(BRAVO_PATCH.read_bytes())
            (root / "alpha.patch").write_bytes(b"tampered\n")
            series = root / "series.json"
            series.write_bytes(TWO_PATCH_SERIES.read_bytes())
            output = root / "series.txt"

            with output.open("w", encoding="utf-8") as stream:
                status = main(["verify", "--series", str(series)], stream)

            self.assertEqual(status, 1)
            self.assertEqual(output.read_text(encoding="utf-8"), "")

    def test_schema_errors_exit_two(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            series = pathlib.Path(directory) / "series.json"
            series.write_text('{"version":1,"patches":[]}', encoding="utf-8")
            output = pathlib.Path(directory) / "series.txt"

            with output.open("w", encoding="utf-8") as stream:
                status = main(["verify", "--series", str(series)], stream)

        self.assertEqual(status, 2)


if __name__ == "__main__":
    unittest.main()
