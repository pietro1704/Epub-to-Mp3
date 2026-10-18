"""Executable Git fixtures for the publication guards; no service calls."""

import hashlib
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
WORKFLOWS = (
    "code-scanning-remediation.yml",
    "dependency-vulnerability-remediation.yml",
    "issue-remediation.yml",
)


class PublicationGuardTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name) / "owned checkout"
        self.root.mkdir()
        self.git("init", "-q")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.invalid")
        (self.root / "source.txt").write_text("baseline\n")
        self.git("add", "--", "source.txt")
        self.git("commit", "-qm", "fixture baseline")
        self.expected = self.git("rev-parse", "HEAD").strip()

    def git(self, *arguments):
        result = subprocess.run(["git", "-C", str(self.root), *arguments],
                                text=True, capture_output=True, check=True)
        return result.stdout

    def publish_guard(self, workflow):
        source = (ROOT / ".github/workflows" / workflow).read_text()
        legacy = [line.strip() for line in source.splitlines()
                  if "if git status --porcelain | grep" in line]
        if legacy:
            self.assertEqual(len(legacy), 1)
            # Execute the actual predecessor predicate, then the actual risky
            # operation it guarded. No commit, remote or service is involved.
            script = "set -euo pipefail\n" + legacy[0] + "\ngit add -A\n"
            return subprocess.run(["/bin/bash", "-c", script], cwd=self.root,
                                  capture_output=True, text=True)
        guard = Path(self.temporary.name) / "trusted-guard.py"
        shutil.copyfile(ROOT / "scripts/guard_remediation_changes.py", guard)
        lines = [line.strip() for line in source.splitlines()
                 if ('"$GUARD_SHA256"' in line and "sha256sum" in line)
                 or '/usr/bin/python3 -I "$TRUSTED_GUARD_PATH"' in line]
        self.assertEqual(len(lines), 2, "trusted hash check and guard invocation are required")
        environment = {**os.environ, "TRUSTED_GUARD_PATH": str(guard),
                       "GITHUB_WORKSPACE": str(self.root), "GUARD_BASE_SHA": self.expected,
                       "GUARD_SHA256": hashlib.sha256(guard.read_bytes()).hexdigest()}
        return subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", "\n".join(lines)],
                              cwd=self.root, env=environment, capture_output=True, text=True)

    def test_actual_workflow_guard_rejects_root_policy_and_credentials_before_staging(self):
        for workflow in WORKFLOWS:
            for filename in (".github/workflows/forbidden.yml", ".env.fixture", "credentials.json"):
                with self.subTest(workflow=workflow, filename=filename):
                    candidate = self.root / filename
                    candidate.parent.mkdir(parents=True, exist_ok=True)
                    candidate.write_text("owned forbidden fixture, never a real secret\n")
                    result = self.publish_guard(workflow)
                    self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                    self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
                    candidate.unlink()


if __name__ == "__main__":
    unittest.main()
