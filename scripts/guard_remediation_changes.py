"""Validate and optionally stage one remediation checkout; never publish it.

Run the trusted pre-agent copy with Python isolated mode. A copy outside the
candidate checkout prevents source edits from replacing this guard; it is not
OS isolation against arbitrary processes running as the same user.
"""

import argparse
import os
from pathlib import Path
import re
import stat
import subprocess
import sys


class Blocked(RuntimeError):
    pass


def protected(filename):
    parts = filename.split("/")
    return (
        not filename or filename.startswith("/") or "\\" in filename
        or any(part in ("", ".", "..") for part in parts)
        or any(ord(character) < 32 or ord(character) == 127 for character in filename)
        or any(part.lower() in {".git", ".github", ".claude", ".codex", ".agents",
                               ".hermes", ".ssh", ".aws", ".azure", ".kube"} for part in parts)
        or re.search(r"(^|/)\.config/gcloud(/|$)|(^|/)\.docker/config\.json$", filename, re.I)
        or re.search(r"(^|/)(AGENTS\.md|CLAUDE\.md|CODEOWNERS|SECURITY\.md|mise\.toml|"
                     r"\.gitmodules|\.gitattributes|\.gitignore|\.netrc|\.npmrc|\.pypirc|auth\.json|"
                     r"\.env[^/]*|[^/]*(credential|secret)[^/]*|"
                     r"[^/]*\.(pem|key|p12|mobileprovision|entitlements))$", filename, re.I)
        or re.search(r"^scripts/(guard_remediation_changes\.py|guarded_pr_merge\.mjs|"
                     r"native_job\.rb|native_build_preflight\.rb|native_codex_tool_guard\.rb|"
                     r"native_build_command\.rb|device-workflow\.sh|ios_simulator_smoke\.swift|"
                     r"guard_ios_simulator_resources\.py|guard_no_python_production\.sh|"
                     r"heavy_job_guard\.py|ios_disk_guard\.sh|preflight\.sh)$", filename)
        or re.search(r"^(docs/agents/|docs/agent-workflow\.md$|TODO_APP\.md$|"
                     r"Dockerfile(?:\.|$)|docker-compose[^/]*$|compose\.[^/]+$|deploy/|infra/)", filename)
    )


def validate(root, expected, stage=False):
    if not re.fullmatch(r"[0-9a-f]{40}", expected):
        raise Blocked("Invalid baseline HEAD")
    root = Path(root).resolve(strict=True)
    environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    environment.update(PATH="/usr/bin:/bin", GIT_OPTIONAL_LOCKS="0", LC_ALL="C")

    def git(*arguments):
        result = subprocess.run(
            ["/usr/bin/git", "--no-replace-objects", "-c", "core.fsmonitor=false",
             "-c", "core.hooksPath=/dev/null", "--literal-pathspecs", "-C", str(root), *arguments],
            env=environment, stdin=subprocess.DEVNULL, capture_output=True, timeout=30,
        )
        if result.returncode:
            raise Blocked("Git validation or explicit staging failed")
        return result.stdout

    def records(output):
        if output and not output.endswith(b"\0"):
            raise Blocked("Incomplete NUL Git records")
        return output[:-1].split(b"\0") if output else []

    def inspect():
        if git("rev-parse", "--verify", "HEAD").strip().decode("ascii") != expected:
            raise Blocked("Remediation HEAD changed from trusted baseline")
        if Path(os.fsdecode(git("rev-parse", "--show-toplevel").strip())).resolve() != root:
            raise Blocked("Unexpected remediation checkout root")
        changes = records(git("status", "--porcelain=v1", "-z", "--untracked-files=all",
                              "--ignore-submodules=none"))
        if not changes:
            raise Blocked("No remediation changes produced")
        paths = []
        for entry in changes:
            if len(entry) < 4 or entry[2:3] != b" " or entry[:2] not in {
                b" M", b"M ", b"MM", b"A ", b"AM", b" D", b"D ", b"??"
            }:
                raise Blocked("Rename, copy, conflict or unsupported Git status refused")
            filename = entry[3:].decode("utf-8", errors="strict")
            if protected(filename):
                raise Blocked("Remediation changes a protected path")
            candidate = root / filename
            for parent in candidate.parents:
                if parent == root:
                    break
                if parent.is_symlink():
                    raise Blocked("Symlink parent refused")
            try:
                if not stat.S_ISREG(candidate.lstat().st_mode):
                    raise Blocked("Only regular remediation files are permitted")
                if not candidate.resolve(strict=True).is_relative_to(root):
                    raise Blocked("Remediation path escapes checkout")
            except FileNotFoundError:
                if b"D" not in entry[:2]:
                    raise Blocked("Remediation path disappeared")
            for row in records(git("ls-tree", "-r", "-z", expected, "--", filename)):
                if row.split(b" ", 1)[0] not in (b"100644", b"100755"):
                    raise Blocked("Baseline symlink or submodule refused")
            for row in records(git("ls-files", "--stage", "-z", "--", filename)):
                metadata = row.split(b"\t", 1)[0].split(b" ")
                if len(metadata) != 3 or metadata[0] not in (b"100644", b"100755") or metadata[2] != b"0":
                    raise Blocked("Index symlink, submodule or conflict refused")
            paths.append(filename)
        git("diff", "--check")
        git("diff", "--cached", "--check")
        return paths

    approved = inspect()
    if stage:
        # Explicit literal pathspecs keep later/unrelated files out of the index.
        git("add", "-A", "--", *approved)
        if set(inspect()) != set(approved):
            raise Blocked("Remediation paths changed during staging")
    return len(approved)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True)
    parser.add_argument("--expected-head", required=True)
    parser.add_argument("--stage", action="store_true")
    args = parser.parse_args()
    try:
        count = validate(args.root, args.expected_head, args.stage)
        print(f"Validated {count} remediation paths")
        return 0
    except (Blocked, OSError, UnicodeError, subprocess.TimeoutExpired) as error:
        print(f"Remediation publication blocked: {type(error).__name__}: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
