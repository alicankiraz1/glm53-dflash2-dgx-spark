import pathlib
import re
import subprocess
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class DocumentationTests(unittest.TestCase):
    def test_operator_entry_points_exist_and_cover_the_cli(self):
        for name in ("README.md", "docs/operator-guide.md", "results/reference/README.md",
                     "scripts/check.sh", ".github/workflows/ci.yml"):
            with self.subTest(path=name):
                self.assertTrue((ROOT / name).is_file(), name)
        guide = (ROOT / "docs/operator-guide.md").read_text()
        for command in ("doctor", "prepare", "launch", "validate", "status", "logs", "stop", "rollback"):
            with self.subTest(command=command):
                self.assertRegex(guide, rf"\b{command}\b")
        for option in ("--run-id", "--plan-digest", "--apply", "--acknowledge-draft-license"):
            self.assertIn(option, guide)
        self.assertNotIn("are planned work and are not yet implemented", (ROOT / "README.md").read_text())

    def test_public_document_links_and_shell_examples(self):
        paths = [ROOT / name for name in ("README.md", "CONTRIBUTING.md", "docs/operator-guide.md",
                                          "results/reference/README.md")]
        for path in paths:
            self.assertTrue(path.is_file(), str(path))
            content = path.read_text()
            for link in re.findall(r"\]\(([^)]+)\)", content):
                target = link.strip("<>").split("#", 1)[0]
                if not target or re.match(r"[a-z]+:", target):
                    continue
                with self.subTest(document=path.name, link=link):
                    self.assertTrue((path.parent / target).is_file(), link)
            for index, block in enumerate(re.findall(r"```(?:bash|sh)\n(.*?)```", content, re.S)):
                with self.subTest(document=path.name, block=index):
                    result = subprocess.run(["/bin/bash", "-n"], input=block, text=True,
                                            capture_output=True, timeout=10)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_ci_actions_are_immutable_and_hardware_scope_is_clear(self):
        workflow = (ROOT / ".github/workflows/ci.yml").read_text()
        uses = re.findall(r"uses:\s+([^\s]+)", workflow)
        self.assertGreaterEqual(len(uses), 2)
        for action in uses:
            self.assertRegex(action, r"^[\w/-]+@[0-9a-f]{40}$")
        self.assertIn("bash scripts/check.sh", workflow)
        self.assertIn("verify_upstream_contract.py", workflow)
        self.assertIn("contents: read", workflow)
        self.assertNotIn("secrets.", workflow)


if __name__ == "__main__":
    unittest.main()
