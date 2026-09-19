"""Score correctness: compare parsed test results against fail_to_pass / pass_to_pass.

Nothing here is allowed to pass quietly. Every way of NOT knowing the answer --
no results, a log that contradicts the runner's exit status, a required test id
that matches two different reported tests -- is a harness error, not a zero. A
zero is a statement about the agent and must be earned.

Writes reward.json, and is the only thing permitted to write a reward of 1.0.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

PASSED, FAILED, ERROR = "PASSED", "FAILED", "ERROR"
HARNESS_ERROR_RC = 3


class Unscoreable(Exception):
    """The trial cannot be graded either way. Carries the reason verbatim."""


def die(reason: str, verifier_dir: Path, totals: tuple[int, int]) -> int:
    payload = {
        "reward": 0.0,
        "resolved": 0,
        "fail_to_pass_total": totals[0],
        "fail_to_pass_passed": 0,
        "pass_to_pass_total": totals[1],
        "pass_to_pass_passed": 0,
        "harness_error": 1,
    }
    (verifier_dir / "reward.json").write_text(json.dumps(payload, indent=2))
    (verifier_dir / "reward.txt").write_text("0\n")
    (verifier_dir / "diagnostic.log").write_text(f"HARNESS ERROR: {reason}\n")
    print(f"HARNESS ERROR: {reason}", file=sys.stderr)
    return HARNESS_ERROR_RC


def required(config: dict, key: str) -> list[str]:
    value = config.get(key) or config.get(key.upper()) or []
    if isinstance(value, str):
        value = json.loads(value)
    return [str(v) for v in value]


def resolve(test_id: str, status: dict[str, str]) -> tuple[str | None, str | None]:
    """Find the reported test for one required id.

    Exact match wins. Failing that, a path-prefix difference is tolerated
    (config says 'foo.py::test_x', pytest printed 'tests/foo.py::test_x') but
    ONLY when exactly one reported test matches -- two candidates means the id
    is ambiguous and the harness genuinely cannot tell which was meant.
    Returns (status, error).
    """
    if test_id in status:
        return status[test_id], None
    hits = [
        name
        for name in status
        if name.endswith("/" + test_id) or test_id.endswith("/" + name)
    ]
    if len(hits) == 1:
        return status[hits[0]], None
    if len(hits) > 1:
        return None, f"{test_id!r} matches {len(hits)} reported tests: {sorted(hits)[:3]}"
    return None, None


def evaluate(
    status: dict[str, str], config: dict, test_rc: int, tampered: int = 0
) -> dict:
    """Score one trial from parsed results. Pure: no IO, no argv, no exit.

    Returns the numeric reward payload. Raises Unscoreable when the trial
    cannot be graded either way -- that is a different outcome from reward 0,
    which is a statement about the agent.
    """
    f2p = required(config, "fail_to_pass")
    p2p = required(config, "pass_to_pass")

    # Guard 1: no results at all is unscoreable. The usual cause is a log_parser
    # that does not match the task's runner -- an authoring bug that would
    # otherwise look exactly like an agent that failed every test.
    if not status:
        raise Unscoreable("no test results were parsed from the run")

    # Guard 2: an ambiguous required id cannot be scored either way.
    f2p_passed, p2p_passed, missing = [], [], {"fail_to_pass": [], "pass_to_pass": []}
    for label, ids, passed in (
        ("fail_to_pass", f2p, f2p_passed),
        ("pass_to_pass", p2p, p2p_passed),
    ):
        for test_id in ids:
            state, err = resolve(test_id, status)
            if err:
                raise Unscoreable(err)
            if state == PASSED:
                passed.append(test_id)
            else:
                missing[label].append(test_id)

    correct = len(f2p_passed) == len(f2p) and len(p2p_passed) == len(p2p)

    # Guard 3: cross-check the log against the runner's own exit status, but
    # only where the two genuinely contradict each other. A non-zero exit while
    # every required test reports PASSED and nothing reports failure is a log
    # that does not describe the run -- forged output, a crashed runner, a
    # parser reading the wrong section. Nothing else explains it.
    #
    # A non-zero exit with required tests MISSING is a different thing entirely
    # and a common one: a test file that fails to compile, or a suite that dies
    # before reaching them. The exit code is explained, the absent tests are
    # correctly scored as not-passed, and the trial is an honest failure.
    # Calling that unscoreable would drop real model failures out of the data.
    reported_failure = any(s in (FAILED, ERROR) for s in status.values())
    if test_rc != 0 and not reported_failure and correct:
        raise Unscoreable(
            f"the test command exited {test_rc} but every required test "
            "reports PASSED and nothing reports failure"
        )

    return {
        "fail_to_pass_total": len(f2p),
        "fail_to_pass_passed": len(f2p_passed),
        "pass_to_pass_total": len(p2p),
        "pass_to_pass_passed": len(p2p_passed),
        # Numeric only -- harbor requires reward.json to be a flat name->number
        # map. The paths themselves go to restore.json.
        "graded_tests_modified_by_agent": tampered,
        "harness_error": 0,
        # The single place a 1.0 is produced, and only with every required test
        # seen PASSED by name above.
        "reward": 1.0 if correct else 0.0,
        "resolved": 1 if correct else 0,
        "_missing": missing,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", required=True, type=Path)
    ap.add_argument("--config", required=True, type=Path)
    ap.add_argument("--test-rc", required=True, type=int)
    ap.add_argument("--verifier-dir", required=True, type=Path)
    ap.add_argument("--restore-manifest", type=Path)
    ap.add_argument("--correctness", required=True, type=Path)
    args = ap.parse_args()

    config = json.loads(args.config.read_text())
    totals = (len(required(config, "fail_to_pass")), len(required(config, "pass_to_pass")))

    results = json.loads(args.results.read_text())
    status = {t["name"]: t["status"] for t in results.get("tests", []) if t.get("name")}

    tampered = 0
    if args.restore_manifest and args.restore_manifest.is_file():
        manifest = json.loads(args.restore_manifest.read_text())
        tampered = len(manifest.get("modified_by_agent", []))

    try:
        payload = evaluate(status, config, args.test_rc, tampered)
    except Unscoreable as exc:
        return die(str(exc), args.verifier_dir, totals)

    missing = payload.pop("_missing")
    args.correctness.write_text(json.dumps(payload))

    for label, ids in missing.items():
        if ids:
            print(f"missing {label} ({len(ids)}): {', '.join(sorted(ids)[:20])}")
    print(
        f"fail_to_pass {payload['fail_to_pass_passed']}/{payload['fail_to_pass_total']}  "
        f"pass_to_pass {payload['pass_to_pass_passed']}/{payload['pass_to_pass_total']}"
    )
    if tampered:
        print(f"NOTE: the agent modified {tampered} graded test file(s); restored before grading")

    (args.verifier_dir / "reward.json").write_text(json.dumps(payload, indent=2))
    (args.verifier_dir / "reward.txt").write_text(f"{payload['reward']}\n")
    print("RESULT:", "PASSED" if payload["resolved"] else "FAILED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
