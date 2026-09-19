"""Restore the graded tests over whatever the agent left behind.

WHY THIS EXISTS. The agent runs as root in the same container that is later
graded, so every file in the repo -- including the tests -- is writable by it.
Two things follow, and both are load-bearing:

  * The repo's git history is NOT a source of truth. `rm -rf .git && git init &&
    git commit` makes the agent's edits the base commit, so any restore that
    reads git faithfully restores the sabotage. Nothing here touches git.

  * The only trustworthy content is content the agent never had access to.
    tests/base_tests/ ships in the task directory and is uploaded to /tests by
    harbor AFTER the agent stops, so it does not exist during the agent phase.
    That is not a permission, it is an absence -- root cannot edit a file that
    is not there yet.

WHAT IT RESTORES. Every file under base_tests, keyed by repo-relative path.
The path list IS the directory listing: there is no separate manifest to drift
out of sync with what is actually graded. If a graded test's file is not in
base_tests, it is not protected -- and that is visible by looking.

`rm -rf` before the copy, deliberately. Replacing a file the agent MODIFIED is
not enough on its own: at a shipped path the agent may have left a directory, a
symlink, or an added file where a graded test now goes. Deleting the target
first handles modified, added and deleted alike.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import sys
from pathlib import Path


def digest(path: Path) -> str | None:
    """Content hash of a file, or None if it is absent or unreadable."""
    try:
        return hashlib.sha256(path.read_bytes()).hexdigest()
    except (OSError, IsADirectoryError):
        return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True, type=Path)
    ap.add_argument("--base-tests", required=True, type=Path)
    ap.add_argument("--manifest", required=True, type=Path)
    args = ap.parse_args()

    if not args.base_tests.is_dir():
        print(f"{args.base_tests} is missing", file=sys.stderr)
        return 1

    sources = sorted(p for p in args.base_tests.rglob("*") if p.is_file())
    if not sources:
        # An empty base_tests means nothing is protected. That is a broken task,
        # not a task to grade leniently: fail here rather than grade the agent's
        # own copy of the tests and call the result a score.
        print(f"{args.base_tests} contains no files", file=sys.stderr)
        return 1

    restored, tampered, added = [], [], []

    for src in sources:
        rel = src.relative_to(args.base_tests)
        dst = args.repo / rel
        want = digest(src)

        # Record what the agent left, before we overwrite it. This is the
        # detection signal -- the restore makes it harmless, but a task whose
        # tests get edited is worth knowing about.
        before = digest(dst)
        if before is None:
            if dst.exists() or not dst.parent.exists():
                pass  # a directory in the way, or no parent yet; both fine
            added.append(str(rel))
        elif before != want:
            tampered.append(str(rel))

        try:
            if dst.exists() or dst.is_symlink():
                if dst.is_dir() and not dst.is_symlink():
                    shutil.rmtree(dst)
                else:
                    dst.unlink()
            dst.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(src, dst)
            # Stamp the restored file as modified NOW. copy2 preserves the
            # source mtime, and base_tests ships in the task dir, so a restored
            # file routinely lands OLDER than build artifacts that the image
            # pre-built. Timestamp-driven build systems -- cargo above all --
            # then judge it unchanged and skip recompiling, so the graded tests
            # never run and every fail_to_pass is scored missing. That looks
            # exactly like a model that failed, and it fires only when the image
            # happens to be built after base_tests was written, so it comes and
            # goes between environments.
            os.utime(dst, None)
        except OSError as exc:
            print(f"could not restore {rel}: {exc}", file=sys.stderr)
            return 1

        # Verify, do not assume. A copy that silently did not land would hand
        # the agent's version to the test runner -- the exact failure this
        # script exists to prevent, and it would look like a normal trial.
        if digest(dst) != want:
            print(f"{rel} does not match base_tests after restore", file=sys.stderr)
            return 1

        restored.append(str(rel))

    args.manifest.write_text(
        json.dumps(
            {
                "restored": restored,
                "modified_by_agent": tampered,
                "absent_before_restore": added,
            },
            indent=2,
        )
    )
    print(f"restored {len(restored)} graded test file(s) from {args.base_tests}")
    if tampered:
        print(f"AGENT MODIFIED {len(tampered)} graded test file(s): {', '.join(sorted(tampered)[:10])}")
    if added:
        print(f"{len(added)} graded test file(s) were absent before the restore")
    return 0


if __name__ == "__main__":
    sys.exit(main())
