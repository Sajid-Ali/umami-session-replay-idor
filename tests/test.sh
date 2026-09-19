#!/bin/bash
# Grading harness for the swe realm. The orchestrator only -- steps live in helpers/.
#
#   1  find the repo
#   2  save the agent's diff        (diagnostic; grading never reads it)
#   3  restore the graded tests     helpers/restore_tests.py
#   4  run the task's test command  helpers/run_tests.sh
#   5  parse the output             log_parsers.py
#   6  score                        helpers/score.py
#
# The one thing to understand before changing anything here: the agent is root
# in this container and owns every file in the repo, including the tests. So
# the graded tests are NOT read from the repo, and NOT restored from git --
# `rm -rf .git && git init && git commit` would make the agent's edits the base
# commit, and any git-based restore would faithfully restore the sabotage.
#
# They are copied from /tests/base_tests, which harbor uploads after the agent
# has stopped and which therefore never existed while the agent was running.
# That is not a permission, it is an absence: root cannot edit a file that is
# not there yet.
#
# See helpers/lib.sh for the reward contract. In short: 1.0 is written only by
# a scorer that saw every required test pass by name, and 0.0 from any failure
# path always carries harness_error=1.

set -euo pipefail

HELPERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/helpers"
. "$HELPERS/lib.sh"

harness_init

step "1 locate repo"
REPO=$(find_repo)
log "repo: $REPO"

step "2 save agent diff"
save_agent_diff "$REPO" >/dev/null

step "3 restore graded tests"
[ -f /tests/config.json ] || die "/tests/config.json is missing"
python3 "$HELPERS/restore_tests.py" \
    --repo "$REPO" \
    --base-tests /tests/base_tests \
    --manifest "$VERIFIER_DIR/restore.json" >>"$RUN_LOG" 2>&1 \
    || die "could not restore the graded tests from /tests/base_tests"

step "4 run tests"
RC_FILE=$(mktemp)
OUT_FILE="$VERIFIER_DIR/test-cmd-stdout.txt"
ERR_FILE="$VERIFIER_DIR/test-cmd-stderr.txt"
bash "$HELPERS/run_tests.sh" "$REPO" "$RUN_LOG" "$RC_FILE" "$OUT_FILE" "$ERR_FILE" \
    || die "the test command could not be launched"
TEST_RC=$(cat "$RC_FILE")

step "5 parse output"
# The runner's own streams, kept separate and free of this harness's output.
python3 /tests/log_parsers.py "$OUT_FILE" "$ERR_FILE" /tmp/results.json /tests/config.json \
    || die "log_parsers.py failed on the test output"
[ -s /tmp/results.json ] || die "log_parsers.py produced no results file"
cp -f /tmp/results.json "$VERIFIER_DIR/results.json"

step "6 score"
set +e
python3 "$HELPERS/score.py" \
    --results /tmp/results.json \
    --config /tests/config.json \
    --test-rc "$TEST_RC" \
    --verifier-dir "$VERIFIER_DIR" \
    --restore-manifest "$VERIFIER_DIR/restore.json" \
    --correctness /tmp/correctness.json 2>&1 | tee -a "$RUN_LOG"
SCORE_RC=${PIPESTATUS[0]}
set -e

# score.py has written its own reward.json and diagnostic; do not overwrite
# them with a vaguer one from the trap.
cp -f "$RUN_LOG" "$VERIFIER_DIR/test-output.txt" 2>/dev/null || true
trap - EXIT
exit "$SCORE_RC"
