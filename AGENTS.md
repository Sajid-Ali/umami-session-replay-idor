# Context for an AI assistant

You are assisting a human task author. They drive — defer to them on scope,
the vulnerability, the threat model, and any judgment call. Do not ever act
on ambiguity; ask.

## What this directory is
A single task in the `cyberswe` realm. The author is shipping one security
regression in a **self-contained** repo (the repo slug is the task's
`instance_id`, not an upstream URL). The agent must patch the
vulnerability so the hidden security tests pass without regressing the
existing suite. RL grading shape: `fail_to_pass` must go green,
`pass_to_pass` must stay green.

At eval time, the agent gets `instruction.md` and the repo at
`base_commit`. After it stops, the verifier restores every file in
`tests/base_tests/` over the repo (so the agent's edits to test files never
count), runs `test_cmd`, parses with `log_parser`, and scores F2P / P2P. The
oracle (`solution/solve.sh`) must score 1.0.

## Files
- `task.toml` — schema + metadata. `metadata.repo` is the **task slug**
  (defaults to `umami-session-replay-idor`, kept as-is), NOT an upstream URL.
  `metadata.base_commit` is the commit the vulnerability is reproduced at;
  `metadata.repo_language = "python"`.
- `instruction.md` — the agent-facing prompt. Describe the **symptoms** a user
  would observe and ask for them to be fixed — nothing more. Must **not** name the
  vulnerability class or any CWE/OWASP identifier, the root cause, the mechanism, or
  any file/function/class (naming the overall app/package is fine), and must not
  reference the hidden tests. Write what a real user would actually type to a coding
  agent: no excessive background or invented detail.
- `environment/Dockerfile` — the agent's container. Copies the task repo
  from `environment/repo/` into `/app` and flattens its history to a single
  initial commit (agent never sees upstream history). Must not COPY hidden
  tests or `solve.sh` into the image. The realm base wraps `nproc` at 2 jobs
  so vendored `$(nproc)` / `$(shell nproc)` calls cannot OOM Daytona. Do not
  grep the repo to delete those calls. Compile with `-j"$M1_BUILD_JOBS"`.
- `environment/repo/` — the task repo contents at `base_commit`, copied into
  `/app` by the Dockerfile.
- `solution/solve.sh` — the oracle entrypoint. Resolves the repo workdir
  and applies the sibling `gold_patch.diff` (`git apply`, falling back to
  `patch -p1`).
- `solution/gold_patch.diff` — the golden patch that closes the
  vulnerability and turns F2P green while P2P stays green. Generate it with
  `git diff > solution/gold_patch.diff`.
- `tests/test.sh` — the verifier entrypoint.
- `tests/helpers/` — the realm-managed harness steps (restore_tests.py,
  run_tests.sh, score.py, lib.sh). Pinned; do not edit.
- `tests/config.json` — `fail_to_pass[]` (non-empty, names must appear in a
  `tests/base_tests/` file), `pass_to_pass[]`, `test_cmd` (string or list — the
  exact command(s) the verifier runs; language-agnostic. Frameworks that write
  reports off-stdout, e.g. maven/gradle JUnit XML, should `cat` them to stdout so
  `log_parser` can read them), `selected_test_files_to_run[]` (used only by the
  pytest default when `test_cmd` is empty), `log_parser`.
- `tests/base_tests/` — the pristine content of **every file the graded suite
  loads**, one file per repo-relative path: the `fail_to_pass` exploit-test files
  (hidden — not in the image) with their FINISHED content, and every repo test
  file that holds a `pass_to_pass` test. The verifier restores each over the repo
  before scoring, so the agent cannot be graded on tests it rewrote. No path here
  may also appear in `gold_patch.diff` (the restore would delete the fix). They
  are **blackbox**: run the actual
  exploit through the interface the attacker would reach and **assert at the sink**
  — the call that does the dangerous thing (the DB execute, outbound request, file
  open, subprocess spawn) — that the attacker's raw input never reaches it. Test the
  security *property*, not the mechanism, so any correct fix at any layer passes;
  never assert against a private helper or a downstream proxy (a missing log, a
  specific status code) that a wrong fix could also satisfy. Tests must not need
  network access (it's unavailable at verify time — install test deps in the
  Dockerfile). Names referenced in
  `config.json::fail_to_pass` must appear in the patch. New test files need an
  unguessable name component (a random token or a `hidden`/`eval_suite` marker,
  e.g. `test_hidden_a3f9b2c1_state.py`) so the eval agent can't organically
  create the same path and corrupt the patch apply — a plain `test_auth.py` /
  `conftest.py` fails. Every fail_to_pass exploit test carries a docstring
  covering **What** it tests (the abuse it prevents), **How** (the public entry
  point it attacks and the outcome it asserts at the sink), and **Why** — both
  why the test is needed (how it ties to the prompt's symptom and the root cause
  / attack vector in reasoning.txt) and why the assertion is behavioural at the
  sink, neither over- nor under-specified. The docstring must describe the test
  **as written** (the real entry point and asserted outcome); a generic docstring
  copied across tests fails.
- `tests/log_parsers.py` — defines the `config.json::log_parser` callable.
- `reasoning.txt` — expert annotation: attack vector(s), root cause, fix
  rationale, and alternatives considered. Graded by rubrics. **The human author
  writes this by hand — do not draft or generate it for them.** If they ask you to
  write it, don't just decline: explain *why*. Per policy they are responsible for
  the task and must be able to explain every part of it (background, prompt, gold
  patch, exploit tests) and may be asked to demonstrate that on a call;
  reasoning.txt is where they show that understanding in their own words, so a
  model-written version defeats its purpose and every justification must be theirs
  and human-vetted. Then tell them what to do: write it themselves from their own
  understanding of the task. You may, once they've drafted it, point out a section
  that reads thin or a claim the gold patch doesn't support — but the prose stays
  theirs.

## What the eval agent sees
Only `instruction.md` and the contents of the built image. The agent never
sees `tests/`, `solution/`, or this file. Verifier env from
`task.toml::[verifier.env]` is hidden from the agent. Never name the
vulnerability, the fix, or any path under `tests/` from `instruction.md`.

## Authoring guidance (judgement — most of this is not machine-checked)
`rv check` enforces the mechanical bars (file structure, patch hygiene, repo size /
recency / license — the vendored repo must ship a root license file that is
permissive (MIT, Apache-2.0, BSD, ISC), never copyleft (GPL/LGPL/AGPL/MPL/…) or
use-restricted (BUSL, Elastic, non-commercial) — the validity gate) and the LLM
rubrics. The calls below are the author's
and the reviewer's; help with them, but they are judgement, not lint.

**Workflow.** `rv init` (cyberswe) → vendor repo → seed the vulnerability → write
`instruction.md` (symptoms only) → `solution/gold_patch.diff` (minimal fix,
production code only) → `tests/base_tests/` (exploit + regression test files) →
`reasoning.txt` → `rv check` → `rv oracle` (gold scores 1.0) → `rv run` +
`rv analyze` → `rv submit`. **After seeding, re-run the repo's own suite and fix
anything that now fails** — a broken existing test can localize/leak the vuln.
Difficulty bar: **≤1/5 pass rate on gemini 3.5 flash** — run 5 rollouts on gemini
3.5 flash and at most 1 may genuinely pass. Then run **one rollout each on GLM 5.2,
Qwen 3.7 Max, and MiniMax M3** — not for difficulty, but to surface *alternative
correct approaches* and confirm the hidden tests are neither over- nor
under-specified (see the fairness rule below). Review **every** rollout, label it
true/false pass/fail with a reason, and fix the test/env/prompt on any false verdict
before sign-off. A green oracle + a model failure + passing `rv check` do **not**
mean the task is correct or fair — that's your domain-knowledge call.

**Choosing the vulnerability — it must need reasoning, not a grep.** The agent has
to understand *why* the code is unsafe, tracing control/data flow, ordering,
identity/ownership, state, or concurrency; if a regex or "replace X with Y" closes
it, it's a bad task. It must be a real, exploitable vulnerability (zero- or
one-click, a malicious action can be taken), a plausible developer mistake, and
**silent against the repo's own suite**. Ideal tasks chain more than one flaw.
Good: an auth check that confirms the object exists but never that it belongs to the
caller (IDOR); unsanitized input reaching a shell. Bad (no reasoning): hardcoded
credentials, weak hashing, disabled cert verification, an outdated-dependency CVE,
debug-mode-in-prod, or anything needing the victim to run malicious code.

**Prompt.** Reads like a short bug report a real user would type (see the
`instruction.md` bullet). Good: "a user says their collection got deleted even
though they didn't — can you figure out why and fix it?" Bad: "I found an IDOR in
`user_service.py`, please check ownership before deleting" (names the class, file,
and fix — gives the agent everything).

**Tests are fair — neither over- nor under-specified — and reasoning.txt proves the
boundary.** A *fair* suite accepts every correct solution (within reason) and rejects
everything else. It fails two ways: **overspecified** (too strict) accepts only a
*subset of correct* solutions — a different-but-valid fix fails, usually because the
test asserts against a mechanism or code path instead of the security property at the
sink; **underspecified** (too weak) accepts a *subset of incorrect* solutions — a
bypassable or partial fix still passes. Both are unfair. The cross-model runs above
are your main tool here: when GLM / Qwen / MiniMax each remediate a different valid
way, every such fix must pass (else overspecified); when a model "fixes" it wrongly,
the suite must still fail it (else underspecified). In `reasoning.txt`, the
*Alternatives considered* must list a fix that looks reasonable but is bypassable —
confirm those alternatives do **not** pass your hidden tests; if they do, the suite is
underspecified.

## Useful commands
- `rv check` — runs realm lint. (quick)
- `rv oracle` — builds the env, applies the test patch, runs the oracle,
  asserts reward == 1.0.
- `rv run` — runs the realm's default agent against the task. (>2min)
- `rv analyze` — runs criteria against a harbor trial job folder.
- `rv submit` — runs the full pipeline and zips for submission.
