#!/bin/bash
set -uo pipefail

CONFIGURED_WORKDIR=""
if [ -f /tests/config.json ]; then
    CONFIGURED_WORKDIR=$(python3 -c "
import json, sys
try:
    cfg = json.load(open('/tests/config.json'))
    repo = cfg.get('repo')
    if isinstance(repo, dict):
        sys.stdout.write((repo.get('repo_dir') or '').strip())
except Exception:
    pass
" 2>/dev/null || true)
fi
RESOLVED_WORKDIR=""
for candidate in "$CONFIGURED_WORKDIR" "/repo" /app /testbed /repo /workspace; do
    if [ -n "$candidate" ] && [ -d "$candidate" ]; then
        cd "$candidate" && RESOLVED_WORKDIR="$candidate" && break
    fi
done
if [ -z "$RESOLVED_WORKDIR" ]; then
    echo "WARNING: Could not find repo workdir; staying at $(pwd)" >&2
fi

if [ -d /var/lib/apt/.a8f1c ] && [ ! -d "$(pwd)/.git/refs/heads" ]; then
    rm -rf "$(pwd)/.git"
    mv /var/lib/apt/.a8f1c "$(pwd)/.git"
fi

# The golden patch ships alongside this script. harbor uploads the whole
# solution/ dir into the container, so gold_patch.diff sits next to solve.sh.
SOLUTION_PATCH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gold_patch.diff"

if [ ! -s "$SOLUTION_PATCH" ]; then
    echo "WARNING: gold_patch.diff is missing or empty; nothing to apply." >&2
else
    APPLIED=0
    if [ -d .git ]; then
        if git apply --whitespace=nowarn --verbose "$SOLUTION_PATCH"; then
            APPLIED=1
        else
            echo "git apply failed, falling back to patch -p1" >&2
        fi
    fi
    if [ "$APPLIED" -eq 0 ]; then
        if patch --fuzz=5 -p1 -i "$SOLUTION_PATCH"; then
            APPLIED=1
        fi
    fi
    if [ "$APPLIED" -ne 1 ]; then
        echo "ERROR: failed to apply gold_patch via either git apply or patch -p1" >&2
        exit 1
    fi
fi

exit 0
