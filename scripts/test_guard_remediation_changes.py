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

    def publish_guard(self, workflow, tamper=False):
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
        digest = hashlib.sha256(guard.read_bytes()).hexdigest()
        if tamper:
            guard.write_text("raise RuntimeError('tampered guard executed')\n")
        lines = [line.strip() for line in source.splitlines()
                 if ('"$GUARD_SHA256"' in line and "sha256sum" in line)
                 or '/usr/bin/python3 -I "$TRUSTED_GUARD_PATH"' in line]
        self.assertEqual(len(lines), 2, "trusted hash check and guard invocation are required")
        environment = {**os.environ, "TRUSTED_GUARD_PATH": str(guard),
                       "GITHUB_WORKSPACE": str(self.root), "GUARD_BASE_SHA": self.expected,
                       "GUARD_SHA256": digest}
        return subprocess.run(["/bin/bash", "-euo", "pipefail", "-c", "\n".join(lines)],
                              cwd=self.root, env=environment, capture_output=True, text=True)

    def test_actual_workflow_guard_rejects_root_policy_and_credentials_before_staging(self):
        for workflow in WORKFLOWS:
            for filename in (".github/workflows/forbidden.yml", ".env.fixture", "credentials.json"):
                with self.subTest(workflow=workflow, filename=filename):
                    candidate = self.root / filename
                    candidate.parent.mkdir(parents=True, exist_ok=True)
                    candidate.write_text("owned forbidden fixture, never a real secret\n")
                    try:
                        result = self.publish_guard(workflow)
                        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
                        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
                    finally:
                        self.git("restore", "--staged", "--", ".")
                        candidate.unlink(missing_ok=True)

    def invoke_helper(self, expected=None, stage=True):
        guard = Path(self.temporary.name) / "trusted-helper.py"
        shutil.copyfile(ROOT / "scripts/guard_remediation_changes.py", guard)
        return subprocess.run(
            ["/usr/bin/python3", "-I", str(guard), "--root", str(self.root),
             "--expected-head", expected or self.expected, *(["--stage"] if stage else [])],
            capture_output=True, text=True, cwd=self.root,
        )

    def test_allowed_changes_use_actual_workflow_guard_and_explicit_staging(self):
        for workflow in WORKFLOWS:
            with self.subTest(workflow=workflow):
                (self.root / "source.txt").write_text("corrected\n")
                literal = self.root / ":(glob)*"
                literal.write_text("literal filename\n")
                try:
                    result = self.publish_guard(workflow)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    names = self.git("diff", "--cached", "--name-only", "-z").split("\0")
                    self.assertEqual(set(names), {"source.txt", ":(glob)*", ""})
                finally:
                    self.git("restore", "--staged", "--", ".")
                    literal.unlink(missing_ok=True)

    def test_ordinary_tooling_source_and_tests_can_be_repaired(self):
        scripts = self.root / "scripts"
        scripts.mkdir()
        for filename in ("conversion_tool.py", "test_conversion_tool.py"):
            (scripts / filename).write_text("# owned tooling code fixture\n")
        result = self.invoke_helper()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(set(self.git("diff", "--cached", "--name-only", "-z").split("\0")),
                         {"scripts/conversion_tool.py", "scripts/test_conversion_tool.py", ""})

    def test_protected_files_staged_unstaged_nested_and_deleted_are_refused(self):
        for filename in ("nested/.github/config.yml", "nested/.env.test", "private.key",
                         "nested/credentials.json", "AGENTS.md", "CLAUDE.md", "mise.toml",
                         "scripts/guard_remediation_changes.py", ".gitmodules", ".npmrc",
                         ".aws/credentials", "app.entitlements", "Dockerfile"):
            with self.subTest(filename=filename):
                candidate = self.root / filename
                candidate.parent.mkdir(parents=True, exist_ok=True)
                candidate.write_text("" if filename == ".gitmodules" else "owned forbidden fixture\n")
                try:
                    self.assertNotEqual(self.invoke_helper().returncode, 0)
                    self.git("add", "--", filename)
                    self.assertNotEqual(self.invoke_helper().returncode, 0)
                finally:
                    self.git("restore", "--staged", "--", ".")
                    candidate.unlink(missing_ok=True)
        protected = self.root / ".env.tracked"
        protected.write_text("owned tracked fixture\n")
        self.git("add", "--", protected.name)
        self.git("commit", "-qm", "tracked protected fixture")
        self.expected = self.git("rev-parse", "HEAD").strip()
        protected.unlink()
        self.assertNotEqual(self.invoke_helper().returncode, 0)

    def test_regular_deletion_is_staged_but_rename_and_type_change_are_refused(self):
        source = self.root / "source.txt"
        source.unlink()
        self.assertEqual(self.invoke_helper().returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--name-status"), "D\tsource.txt\n")
        self.git("restore", "--staged", "--worktree", "--", ".")
        self.git("mv", "source.txt", "renamed.txt")
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        self.git("restore", "--staged", "--worktree", "--", ".")
        (self.root / "renamed.txt").unlink(missing_ok=True)
        source.unlink()
        source.symlink_to("outside")
        self.assertNotEqual(self.invoke_helper().returncode, 0)

    def test_nul_records_do_not_hide_newlines_tabs_or_backslashes(self):
        for filename in ("safe\n.env", "safe\tname", "safe\\name", "nested/evil\n.github"):
            with self.subTest(filename=filename):
                candidate = self.root / filename
                candidate.parent.mkdir(parents=True, exist_ok=True)
                candidate.write_text("owned fixture\n")
                try:
                    self.assertNotEqual(self.invoke_helper().returncode, 0)
                    self.assertEqual(self.git("diff", "--cached", "--name-only"), "")
                finally:
                    candidate.unlink()

    def test_symlinks_deleted_symlinks_and_gitlinks_are_refused(self):
        link = self.root / "link"
        link.symlink_to("source.txt")
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        self.git("add", "--", "link")
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        self.git("commit", "-qm", "tracked symlink fixture")
        self.expected = self.git("rev-parse", "HEAD").strip()
        link.unlink()
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        self.git("restore", "--worktree", "--", "link")
        self.git("update-index", "--add", "--cacheinfo", f"160000,{self.expected},module")
        self.assertNotEqual(self.invoke_helper().returncode, 0)

    def test_nested_git_directory_is_not_silently_added_as_submodule(self):
        nested = self.root / "nested-repository"
        nested.mkdir()
        subprocess.run(["git", "-C", str(nested), "init", "-q"], check=True, capture_output=True)
        (nested / "file").write_text("owned fixture\n")
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")

    def test_symlink_parent_cannot_redirect_a_tracked_deletion_outside_checkout(self):
        nested = self.root / "nested"
        nested.mkdir()
        (nested / "file.txt").write_text("tracked baseline\n")
        self.git("add", "--", "nested/file.txt")
        self.git("commit", "-qm", "tracked nested fixture")
        self.expected = self.git("rev-parse", "HEAD").strip()
        shutil.rmtree(nested)
        foreign = Path(self.temporary.name) / "foreign"
        foreign.mkdir()
        (foreign / "file.txt").write_text("preserve foreign bytes\n")
        nested.symlink_to(foreign, target_is_directory=True)
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        self.assertEqual((foreign / "file.txt").read_text(), "preserve foreign bytes\n")

    def test_clean_tree_and_changed_baseline_are_refused(self):
        self.assertNotEqual(self.invoke_helper().returncode, 0)
        (self.root / "source.txt").write_text("fix\n")
        self.assertNotEqual(self.invoke_helper(expected="a" * 40).returncode, 0)
        self.assertEqual(self.git("diff", "--cached", "--name-only"), "")

    def test_actual_git_failure_blocks_publication(self):
        metadata = self.root / ".git"
        detached = Path(self.temporary.name) / "owned-git-metadata"
        metadata.rename(detached)
        try:
            result = self.invoke_helper()
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Git validation or explicit staging failed", result.stderr)
        finally:
            detached.rename(metadata)

    def test_hash_check_blocks_changed_trusted_copy_before_it_can_execute(self):
        (self.root / "source.txt").write_text("fix\n")
        for workflow in WORKFLOWS:
            with self.subTest(workflow=workflow):
                result = self.publish_guard(workflow, tamper=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("tampered guard executed", result.stderr)
                self.assertEqual(self.git("diff", "--cached", "--name-only"), "")

    def test_workflow_freezes_trusted_copy_before_codex_and_never_stages_globally(self):
        for workflow in WORKFLOWS:
            with self.subTest(workflow=workflow):
                source = (ROOT / ".github/workflows" / workflow).read_text()
                self.assertLess(source.index("install -m 0444 scripts/guard_remediation_changes.py"),
                                source.index("codex exec"))
                self.assertIn("ref: master", source)
                self.assertIn("${{ steps.publication_guard.outputs.base_sha }}", source)
                self.assertIn("${{ steps.publication_guard.outputs.guard_sha256 }}", source)
                self.assertNotIn("git add -A", source)
                self.assertNotIn("git status --porcelain | grep", source)


if __name__ == "__main__":
    unittest.main()
