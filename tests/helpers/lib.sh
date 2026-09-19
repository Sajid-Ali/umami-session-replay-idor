# helpers/lib.sh -- shared primitives. Sourced by test.sh, never executed.
#
# THE REWARD CONTRACT. Exactly two files write reward.json:
#
#   lib.sh    every failure it detects  -> reward 0.0, harness_error=1
#   score.py  a scored trial            -> reward 0.0 or 1.0, harness_error=0
#             a failure it detects      -> reward 0.0, harness_error=1
#
# So there are two shapes, not three: "we scored it" and "we could not". Which
# file wrote it does not matter to a consumer; harness_error does.
#
# Nothing else may write reward.json. The two invariants that matter:
#
#   * reward 1.0 is never written by a fallback. It is written only after a
#     scorer has seen every required test reported PASSED by name. A harness
#     that guesses 1.0 from an exit status pays a cheating agent in full.
#   * reward 0.0 written by a failure path ALWAYS carries harness_error=1.
#     Otherwise "the harness broke" is indistinguishable from "the model
#     failed", which silently deflates every pass rate computed downstream.

HARNESS_ERROR_RC=3
VERIFIER_DIR=/logs/verifier
RUN_LOG=""

harness_init() {
    mkdir -p "$VERIFIER_DIR"
    # The X's must end the template: BSD mktemp (macOS) rejects a suffix
    # after them, which makes the harness untestable outside the container.
    RUN_LOG=$(mktemp /tmp/harness-run.XXXXXX)
    export RUN_LOG VERIFIER_DIR HARNESS_ERROR_RC
    # Always ship the log, and never leave the trial without a reward.json --
    # a missing one makes harbor error out opaquely instead of recording why.
    trap '_on_exit $?' EXIT
}

_on_exit() {
    local rc=$1
    cp -f "$RUN_LOG" "$VERIFIER_DIR/test-output.txt" 2>/dev/null || true
    if [ ! -f "$VERIFIER_DIR/reward.json" ]; then
        # Reached the end with no score. Whatever happened, it was not a pass.
        _write_harness_error "the harness exited ${rc} without writing a reward"
    fi
}

log()  { printf '%s\n' "$*" | tee -a "$RUN_LOG" >&2; }
step() { printf '\n=== %s ===\n' "$*" >> "$RUN_LOG"; }

_write_harness_error() {
    printf '{"reward":0.0,"resolved":0,"harness_error":1}\n' > "$VERIFIER_DIR/reward.json"
    printf '0\n' > "$VERIFIER_DIR/reward.txt"
    printf 'HARNESS ERROR: %s\n' "$*" > "$VERIFIER_DIR/diagnostic.log"
    printf 'HARNESS ERROR: %s\n' "$*" >&2
}

# Stop the run, say why, mark it unscoreable. Every failure path lands here.
die() {
    _write_harness_error "$*"
    cp -f "$RUN_LOG" "$VERIFIER_DIR/test-output.txt" 2>/dev/null || true
    trap - EXIT
    exit "$HARNESS_ERROR_RC"
}

# The repo is wherever the image put it. No default guess beyond these.
find_repo() {
    local d
    for d in /repo /app /testbed /workspace; do
        [ -d "$d" ] && { printf '%s\n' "$d"; return 0; }
    done
    die "no repo found at /repo, /app, /testbed or /workspace"
}

# Diagnostic only: what the agent changed. Never read by grading -- the agent
# owns this git history and can rewrite it, so it is evidence, not authority.
save_agent_diff() {
    local repo=$1 base
    base=$(git -C "$repo" rev-list --max-parents=0 HEAD 2>/dev/null | tail -1 || true)
    git -C "$repo" add -A 2>/dev/null || true
    git -C "$repo" diff --cached "${base:-HEAD}" > "$VERIFIER_DIR/agent_patch.diff" 2>/dev/null \
        || log "WARNING: could not capture agent_patch.diff (diagnostic only)"
    printf '%s\n' "${base:-HEAD}"
}
