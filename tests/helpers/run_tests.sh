#!/bin/bash
# Run the task's test command and record its TRUE exit status.
#
# Usage: run_tests.sh <repo> <run_log> <rc_file> <stdout_file> <stderr_file>
#
# stdout and stderr are captured to SEPARATE files, and those are what the
# parser reads. Two reasons, both learned the hard way:
#
#   * Merging them with `2>&1` interleaves two writers on one fd in real time,
#     which can splice a warning through the middle of a `test foo ... ok` line
#     and make it stop matching. Runners split their streams (cargo and go put
#     results on stdout, jest puts them on stderr), so both must be kept and
#     both must be intact.
#   * The run log also carries THIS harness's own output -- restore counts, the
#     command line. A parser handed that log is parsing our chatter alongside
#     the runner's. It must only ever see what the test command wrote.
#
# The exit status matters even though the score comes from the parsed output:
# it is the cross-check. Anything in the repo can print a line that looks like a
# pass. A runner that exits non-zero while the log reports no failure is a log
# that does not describe the run that happened. So the status is captured
# immediately, written to its own file, and this script always exits 0 --
# failing tests are the normal case, not an error.

set -uo pipefail

REPO=$1; RUN_LOG=$2; RC_FILE=$3; OUT_FILE=$4; ERR_FILE=$5

# A list `test_cmd` is a list of INDEPENDENT commands, not a pipeline. Joining
# them with `&&` would let one failure suppress the rest -- and the first entry
# is often the hidden F2P suite, whose failure is the normal case. On a Rust
# task that meant a test file which did not compile took the whole P2P suite
# with it, turning an honest 0.0 into an unscoreable trial. Each entry runs, in
# order, whatever the previous one returned.
CMD_DIR=$(mktemp -d)
python3 -c "
import json, pathlib, sys
with open('/tests/config.json') as f:
    cmds = json.load(f).get('test_cmd') or []
if isinstance(cmds, str):
    cmds = [cmds]
cmds = [c for c in cmds if isinstance(c, str) and c.strip()]
if not cmds:
    sys.exit(1)
for i, c in enumerate(cmds):
    pathlib.Path('$CMD_DIR', f'{i:03d}.sh').write_text(c)
" || { echo "config.json declares no test_cmd" >&2; exit 1; }

cd "$REPO" || { echo "could not enter $REPO" >&2; exit 1; }
: > "$OUT_FILE"; : > "$ERR_FILE"
FINAL_RC=0
for step in "$CMD_DIR"/*.sh; do
    echo "running in $REPO: $(cat "$step")" >> "$RUN_LOG"
    bash "$step" >> "$OUT_FILE" 2>> "$ERR_FILE"
    rc=$?
    # Any failing step makes the run "failed" for the exit-status cross-check,
    # without stopping the steps that follow.
    [ "$rc" -ne 0 ] && FINAL_RC=$rc
done
printf '%s\n' "$FINAL_RC" > "$RC_FILE"

# The human-readable log gets a copy; the parser gets the originals.
{ echo "--- stdout ---"; cat "$OUT_FILE"; echo "--- stderr ---"; cat "$ERR_FILE"; } >> "$RUN_LOG"
echo "test command exited $(cat "$RC_FILE")" >> "$RUN_LOG"
exit 0
