import hashlib
import json
import pathlib
import re
import unittest

from tools.config_state import load_reproduction_lock
from tools.patch_series import verify_patch_series


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ReproductionLockTests(unittest.TestCase):
    def test_lifecycle_image_probe_reads_a_label_set_by_the_build(self):
        containerfile = (ROOT / "runtime/Containerfile").read_text()
        lifecycle = (ROOT / "lib/lifecycle.sh").read_text()
        probe = next(line for line in lifecycle.splitlines()
                     if line.startswith("readonly _GLM53_LIFECYCLE_IMAGE_FORMAT="))
        label = re.search(r'Labels "([^"]+)"', probe).group(1)
        self.assertIn(f'LABEL {label}="glm53-spark"', containerfile)

    def test_every_shipped_artifact_matches_the_lock(self):
        lock = load_reproduction_lock(ROOT / "config/reproduction.lock.json")
        pairs = [
            (lock.target_model.manifest_path, lock.target_model.manifest_sha256),
            (lock.draft_model.manifest_path, lock.draft_model.manifest_sha256),
            (lock.runtime.containerfile_path, lock.runtime.containerfile_sha256),
            (lock.runtime.patch_series_path, lock.runtime.patch_series_sha256),
        ]
        for name, expected in pairs:
            with self.subTest(path=name):
                path = ROOT / name
                self.assertFalse(path.is_symlink())
                self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), expected)
        self.assertEqual(verify_patch_series(ROOT / lock.runtime.patch_series_path), [])

    def test_documented_profile_keeps_the_historical_correctness_boundary(self):
        profile = json.loads((ROOT / "config/reproduction.lock.json").read_text())["profile"]
        expected = {
            "tensor_parallel_size": 4, "nnodes": 4, "context_length": 131072,
            "max_running_requests": 4, "dflash_block_size": 8,
            "speculative_num_draft_tokens": 8, "speculative_algorithm": "DFLASH",
            "draft_attention_backend": "fa4", "kv_cache_dtype": "bfloat16",
            "radix_cache": False,
        }
        self.assertEqual({key: profile[key] for key in expected}, expected)


if __name__ == "__main__":
    unittest.main()
