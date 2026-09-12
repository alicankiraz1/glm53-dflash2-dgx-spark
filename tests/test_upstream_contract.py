import json
import pathlib
import unittest

from tools.verify_upstream_contract import generated_options, registered_options


ROOT = pathlib.Path(__file__).resolve().parents[1]


class UpstreamContractTests(unittest.TestCase):
    def test_actual_rank_arguments_match_the_pinned_source_snapshot(self):
        contract = json.loads((ROOT / "tests/fixtures/sglang-cli.json").read_text())
        lock = json.loads((ROOT / "config/reproduction.lock.json").read_text())
        self.assertEqual(contract["revision"], lock["runtime"]["sglang_commit"])
        self.assertEqual(len(contract["source_sha256"]), 64)
        allowed = set(contract["options"])
        for rank in range(4):
            with self.subTest(rank=rank):
                actual = generated_options(ROOT, rank)
                self.assertFalse(actual - allowed, sorted(actual - allowed))
                self.assertIn("--speculative-dflash-block-size", actual)
                self.assertIn("--speculative-draft-attention-backend", actual)
                self.assertNotIn("--dflash-block-size", allowed)
                self.assertNotIn("--draft-attention-backend", allowed)

    def test_metadata_controls_registration_not_just_field_names(self):
        source = '''
class ServerArgs:
    internal: int = 1
    hidden: A[int, Arg(no_cli=True)] = 1
    plain: A[int, "help", NS("spec")] = 1
    renamed: A[str, Arg(cli_name="--public", aliases=["--alias"])] = ""
    def add_cli_args(parser):
        parser.add_argument("--manual", type=str)
'''
        self.assertEqual(
            registered_options(source),
            {"--plain", "--public", "--alias", "--manual"},
        )

    def test_missing_server_args_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "ServerArgs"):
            registered_options("class Other: pass")


if __name__ == "__main__":
    unittest.main()
