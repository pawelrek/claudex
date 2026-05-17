# /claudex — Plan + implement a feature with Codex as the cross-reviewer

Drives a Claude (plan + implement) ↔ Codex (review) loop so the user doesn't have to copy-paste between the two agents.

This skill is project-agnostic. It defers all codebase-specific knowledge (tech stack, architectural rules, routing of work to specialist agents, commit-message conventions, etc.) to the project's `CLAUDE.md` if one exists. Drop the file into any Claude Code project and it works.

**Flow**

```
ARG (feature spec)
  │
  ▼
                  ┌──────────────────────────────────────────────────────────────┐
                  │           PLAN LOOP (score-gated, ≤ 6 rounds)                │
                  │  [Claude] plan ──► [Codex] score ──► refine if ≤ 8.5 or any  │
                  │                                       BLOCKING item present  │
                  └──────────────────────────┬───────────────────────────────────┘
                                             │  (score > 8.5 AND 0 BLOCKING)
                                             ▼
                                     [Claude] implement
                                             │
                  ┌──────────────────────────▼───────────────────────────────────┐
                  │         IMPLEMENTATION LOOP (score-gated, ≤ 6 rounds)        │
                  │  [Codex] score diff ──► [Claude] fix if ≤ 8.5 or BLOCKING    │
                  └──────────────────────────┬───────────────────────────────────┘
                                             │  (score > 8.5 AND 0 BLOCKING)
                                             ▼
                              report + iteration tables + stop
```

Both review loops are **score-gated**: each round Codex emits a numeric SCORE (1.0–10.0), a (possibly empty) `BLOCKING:` list of must-fix items, and a (possibly empty) `ADVISORY:` list of non-blocking polish notes. The loop converges only when **score > 8.5 AND the BLOCKING list is empty** — ADVISORY items are surfaced but never block. Safety backstop on each loop: **6 rounds**. Past the cap, we surface unresolved BLOCKING items + the final score and move on. Fully automatic — no user prompts between rounds.

Resilient to Codex session-token exhaustion: a failed or empty Codex round renders an `EMPTY` verdict banner, records `session_error` as the loop's exit reason, exits the current loop gracefully, and continues to the report (skipping any downstream loops that would need a successful review to be meaningful). No hangs, no hard halts.

State that has to survive between separated Bash calls is persisted to **files** under `$RUN_DIR`. Cross-snippet shell helpers live in `$RUN_DIR/lib.sh` and are sourced at the top of each snippet that needs them. `$RUN_DIR` itself is **not** read from a pointer file; it's threaded through every Bash invocation by the runtime model (see "Bash snippet convention" below) — that's robust against parallel `/claudex` runs in different chats.

---

## Privacy and run artifacts

`/claudex` writes a substantial paper trail under `.claude/claudex/<timestamp>/` on every run. Artifacts can contain:

- The verbatim feature spec the user typed (which may include customer data, internal terminology, paths, secrets accidentally pasted into the prompt, etc.)
- Source code and diffs from the project
- Stack traces, file paths, and error messages from any failures
- Codex's per-round reasoning + token-usage telemetry (in the JSONL streams)

**Local artifacts only — but model calls leave the machine.** All run artifacts under `.claude/claudex/` stay on disk. However, the model invocations themselves *do* send data over the network: Codex calls send the relevant prompt/code/diff to the configured Codex provider, and Claude (planner / refiner / implementer / fixer) calls send their prompts and any tool inputs to the configured Claude provider. Both providers' privacy and retention policies apply.

**Before invoking, verify `.claude/claudex/` is gitignored.** Step 0j probes this and warns if not.

**Disposal:**
- `rm -rf .claude/claudex/<timestamp>/` after a run, OR `rm -rf .claude/claudex/` to clear all runs.
- A periodic cron (e.g. `find .claude/claudex -mindepth 1 -maxdepth 1 -type d -mtime +30 -exec rm -rf {} +`) to prune by age.

**Persistent prompt header is truncated by default.** The visible-in-every-reply header only shows the first ~200 chars of the spec; the full text lives at `$RUN_DIR/prompt.md`. Screenshots and shared logs therefore don't leak the entire feature spec.

---

## Bash snippet convention

Every Bash snippet below assumes `$RUN_DIR` is already set to the literal timestamped path captured at Step 0b. The runtime model is responsible for prefixing every Bash tool call with `RUN_DIR=<literal>` so the snippet's references resolve in a fresh shell. Example:

```bash
RUN_DIR=.claude/claudex/20260517-120000      # literal path from this run's Step 0b output
source "$RUN_DIR/lib.sh"
# … rest of snippet …
```

This is more robust than reading a `latest-run` pointer file, because parallel `/claudex` invocations in different chats would race on that pointer. (A `.claude/claudex/latest-run` file is still written at Step 0b as a human-readable convenience so you can `cat .claude/claudex/latest-run` to find the most recent run from a terminal — but the skill itself does not depend on it programmatically.)

Snippets also typically source `$RUN_DIR/lib.sh` (written once at Step 0g) for shared helpers: `with_timeout`, `blocking_count_robust`, `advisory_count_robust`, `baseline_paths`.

---

## Invocation

```
/claudex <feature description>
```

The feature description comes in as `$ARGUMENTS`. If empty, ask the user once for a one-paragraph spec before doing anything else.

---

## Step 0 — Preflight

This is the ONE snippet where `$RUN_DIR` is set inline (since it's the snippet that creates the run directory). Every later snippet receives `$RUN_DIR` from the runtime model per the convention above.

```bash
# 0pre. Git repo + valid HEAD — hard precondition for every later step
#       (rev-parse, diff, commits all assume both). Fail before anything
#       else so we don't burn a smoke probe before discovering we can't
#       actually do anything with the result.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "Not inside a git work tree. /claudex requires a git repository."
  exit 1
}
git rev-parse --verify HEAD >/dev/null 2>&1 || {
  echo "Git HEAD is invalid (empty repo? mid-rebase? unborn branch?). /claudex requires a working HEAD commit."
  exit 1
}

# 0a. Codex CLI present.
command -v codex >/dev/null || { echo "codex CLI not installed. Run: npm install -g @openai/codex"; exit 1; }

# 0b. Scratch dir + human-convenience pointer.
#     The pointer file (.claude/claudex/latest-run) is a human-readable
#     shortcut (`cat .claude/claudex/latest-run`); the skill itself does
#     NOT read this — the runtime model threads $RUN_DIR through every
#     subsequent Bash invocation explicitly.
RUN_DIR=".claude/claudex/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$RUN_DIR"
mkdir -p .claude/claudex
echo "$RUN_DIR" > .claude/claudex/latest-run
echo "Scratch dir: $RUN_DIR"

# 0c. Persist the verbatim user prompt IMMEDIATELY — it's the input to every
#     Codex reviewer prompt AND the source of the ORIGINAL-PROMPT header.
#     Writing it first means any later failure still leaves the spec on disk.
printf '%s\n' "$ARGUMENTS" > "$RUN_DIR/prompt.md"

# 0d. Persist runtime constants.
echo "8.5" > "$RUN_DIR/score-target"
echo "6"   > "$RUN_DIR/max-rounds"
echo "6"   > "$RUN_DIR/max-fix-rounds"

# 0e. Initialize exit-reason state files.
echo "unknown" > "$RUN_DIR/plan.exit-reason"
echo "unknown" > "$RUN_DIR/impl.exit-reason"

# 0f. Portable timeout binary detection.
TIMEOUT_BIN=$(command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null || echo "")
echo "$TIMEOUT_BIN" > "$RUN_DIR/timeout-bin"

# 0g. Write the shared shell library. Sourced by every snippet that needs
#     helpers. Functions defined here work identically under bash and zsh.
cat > "$RUN_DIR/lib.sh" <<'LIB'
# /claudex shared shell library

# Run a command under a wall-clock timeout if `timeout`/`gtimeout` is available;
# otherwise run it unwrapped. Portable across bash and zsh — does NOT rely on
# parameter-expansion word splitting (which is on in bash, off by default in zsh).
with_timeout() {
  local secs="$1"; shift
  if [ -n "${TIMEOUT_BIN:-}" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
  else
    "$@"
  fi
}

# Count items under a BLOCKING heading: numbered (1.), bulleted (-, *, +).
# Sections are delimited by ADVISORY: or `---`.
_count_listed_under_blocking() {
  awk '
    /^BLOCKING:/ { in_b=1; in_a=0; next }
    /^ADVISORY:/ { in_b=0; in_a=1; next }
    /^---/       { in_b=0; in_a=0; next }
    in_b && /^[[:space:]]*([0-9]+\.|[-*+])/ { n++ }
    END { print n+0 }
  ' "$1"
}

# Count items under an ADVISORY heading — same shape.
_count_listed_under_advisory() {
  awk '
    /^ADVISORY:/ { in_a=1; in_b=0; next }
    /^BLOCKING:/ { in_a=0; in_b=1; next }
    /^---/       { in_a=0; in_b=0; next }
    in_a && /^[[:space:]]*([0-9]+\.|[-*+])/ { n++ }
    END { print n+0 }
  ' "$1"
}

# Count non-empty body lines under BLOCKING (fallback when list-item parser
# returns zero for a non-empty section — e.g. plain-text items).
_count_body_under_blocking() {
  awk '
    /^BLOCKING:/ { in_b=1; next }
    /^(ADVISORY:|---)/ { in_b=0 }
    in_b && NF > 0 { n++ }
    END { print n+0 }
  ' "$1"
}

# Robust BLOCKING counter: list-item count first, fall back to non-empty body
# lines if BLOCKING heading is present but the parser saw zero list items
# (handles Codex returning plain text under BLOCKING:).
blocking_count_robust() {
  local file="$1" items has_heading body
  items=$(_count_listed_under_blocking "$file")
  # Avoid `grep -c | echo 0` which double-prints (grep emits "0" on no-match
  # but exits 1, triggering the fallback echo — yielding "0\n0" and a noisy
  # "integer expression expected" under stricter shells).
  if grep -q '^BLOCKING:' "$file" 2>/dev/null; then
    has_heading=1
  else
    has_heading=0
  fi
  if [ "$has_heading" -gt 0 ] && [ "$items" -eq 0 ]; then
    body=$(_count_body_under_blocking "$file")
    if [ "$body" -gt 0 ]; then
      echo "WARNING: BLOCKING heading present but no list-style items parsed (Codex may have used plain text or unusual formatting). Treating non-empty body lines as $body BLOCKING item(s)." >&2
      echo "$body"
      return
    fi
  fi
  echo "$items"
}

# Robust ADVISORY counter — same idea, but the false-positive risk is lower
# (ADVISORY never gates convergence), so we just use the list-item count.
advisory_count_robust() {
  _count_listed_under_advisory "$1"
}

# Return the set of pre-existing dirty paths (one per line) as captured at
# preflight in baseline-dirty-paths.txt. The list is path-only and UNQUOTED,
# so it compares cleanly with `git diff --name-only -z` output later (porcelain
# without -z quotes paths containing spaces; `git diff --name-only` doesn't,
# so a quote-vs-no-quote mismatch would let leaked paths slip through).
baseline_paths() {
  if [ -s "$RUN_DIR/baseline-dirty-paths.txt" ]; then
    cat "$RUN_DIR/baseline-dirty-paths.txt"
  fi
}
LIB

# 0h. Smoke probe — `codex exec --help` only validates the binary, not the
#     auth/session. Run a tiny real exec to prove Codex can actually talk.
source "$RUN_DIR/lib.sh"
echo "Reply with exactly the token OK and nothing else." > "$RUN_DIR/probe.in"
with_timeout 30 codex exec \
  --skip-git-repo-check \
  -s read-only \
  -c model="gpt-5.2" \
  -c model_reasoning_effort="low" \
  --output-last-message "$RUN_DIR/probe.out" \
  - < "$RUN_DIR/probe.in" > "$RUN_DIR/probe.jsonl" 2>&1
PROBE_RC=$?
if [ "$PROBE_RC" -ne 0 ] || [ ! -s "$RUN_DIR/probe.out" ]; then
  echo "Codex smoke probe failed (rc=$PROBE_RC). Likely causes: codex not logged in (run 'codex login'), expired session, no network, or quota exhausted."
  tail -20 "$RUN_DIR/probe.jsonl"
  exit 1
fi
if ! grep -q "OK" "$RUN_DIR/probe.out"; then
  echo "Codex smoke probe returned unexpected content (continuing — auth looks fine):"
  cat "$RUN_DIR/probe.out"
fi

# 0i. Baseline dirt snapshot — sorted/deduped porcelain of any pre-existing
#     non-scratch uncommitted changes. Post-delegate checks (Steps 3 + 5)
#     reject only NEW dirt against this snapshot AND reject any pre-existing
#     dirty PATH that the delegate folded into its commit (a separate failure
#     mode that delta-against-dirt alone wouldn't catch).
git status --porcelain | grep -Ev '^\?\? \.claude/claudex/' \
  | LC_ALL=C sort -u > "$RUN_DIR/baseline-dirt.txt" || true
if [ -s "$RUN_DIR/baseline-dirt.txt" ]; then
  echo "Working tree has pre-existing uncommitted changes:"
  cat "$RUN_DIR/baseline-dirt.txt"
  echo "(snapshotted to $RUN_DIR/baseline-dirt.txt — post-delegate checks will reject NEW dirt AND any pre-existing path that gets committed.)"
fi

# 0i (bis). Path-only snapshot for leak detection (Check 3 in Steps 3 + 5).
#          Uses `-z` so paths containing spaces aren't quoted (porcelain
#          without -z quotes them; `git diff --name-only -z` doesn't), so
#          the two sides of the comm comparison line up. Handles porcelain's
#          rename format under -z: a record starting with R/C is followed by
#          a separate NUL-terminated record holding the source path.
{
  git status --porcelain -z 2>/dev/null | tr '\0' '\n' | awk '
    $0 == "" { next }
    prev_was_rename { print; prev_was_rename=0; next }
    {
      code = substr($0, 1, 2)
      path = substr($0, 4)
      print path
      if (code ~ /^[RC]/) prev_was_rename=1
    }' | grep -v '^\.claude/claudex/' || true
} | LC_ALL=C sort -u > "$RUN_DIR/baseline-dirty-paths.txt"

# 0j. Gitignore probe — warn if $RUN_DIR's contents could leak into commits.
if ! git check-ignore -q ".claude/claudex/probe-file" 2>/dev/null; then
  echo ""
  echo "⚠ Warning: .claude/claudex/ does NOT appear to be gitignored."
  echo "  Run artifacts can include your prompt, Codex prompts + responses, diffs,"
  echo "  and JSONL streams. Add this line to .gitignore before continuing:"
  echo "    .claude/claudex/"
  echo ""
fi
```

Paper trail at end-of-run (under `$RUN_DIR/`):

| Path | Purpose |
|------|---------|
| `prompt.md`                       | Verbatim user spec. |
| `lib.sh`                          | Shared shell helpers (sourced by every snippet). |
| `score-target` / `max-rounds` / `max-fix-rounds` | Runtime constants. |
| `plan.exit-reason` / `impl.exit-reason` | Single source of truth for how each loop ended. |
| `plan.round` / `impl.round`       | Current round counter. |
| `timeout-bin`                     | Path to `timeout` / `gtimeout`, or empty. |
| `baseline-dirt.txt`               | Snapshot of working-tree dirt at preflight (sorted, deduped). |
| `plan.v{N}.md`                    | Plan revisions, one per round. |
| `prompt.review.v{N}.txt` / `prompt.review.diff.v{M}.txt` | Codex prompt files. |
| `review.v{N}.md` / `review.diff.v{M}.md` | Codex responses. May be appended-to with `ORCHESTRATOR-SYNTHESIZED BLOCKING:` if Codex returned a malformed low-score review. |
| `codex.v{N}.jsonl` / `codex.diff.v{M}.jsonl` | Codex JSONL streams. |
| `codex.v{N}.rc` / `codex.diff.v{M}.rc` | Codex exit codes. |
| `impl.v{M}.diff`                  | Cumulative diff snapshot per fix-pass round. |
| `plan-iterations.tsv` / `impl-iterations.tsv` | Append-only iteration logs. Status column: `OK` / `MALFORMED` / `SESSION_ERROR`. |
| `plan-iterations.md` / `impl-iterations.md` | Rendered Markdown tables. |
| `base.sha` / `impl.sha` / `fixup.shas` / `impl.final-score` | Commit bookkeeping. |
| `probe.*`                          | Smoke-probe artifacts. |

---

## Persistent ORIGINAL-PROMPT header rule (applies to every text reply during this run)

`/claudex` is invoked for long-form work (plans, bug reports with stack traces, multi-paragraph specs). The standard `~/.claude/CLAUDE.md` response header only restates the user's *current turn* — but in a multi-round cross-review most user turns are short ("continue", "ok run codex again"), so the standard header loses the load-bearing context.

**Rule:** for the entire duration of a `/claudex` run (Steps 1–6), the orchestrator's TEXT reply on every turn MUST prepend this block ABOVE the standard CLAUDE.md `> **Original prompt:** …` header:

```
📌 CLAUDEX · ORIGINAL PROMPT (run: $RUN_DIR)
─────────────────────────────────────────────
<first 200 chars of $ARGUMENTS, single-line, with literal newlines collapsed to spaces>… [full prompt at $RUN_DIR/prompt.md]
─────────────────────────────────────────────
```

**Truncation is the default, not the exception.** Always cap the visible portion at 200 chars and append the disk pointer. The inline header is a task identifier, not a full record — the full text lives on disk. This makes parallel multi-chat use safer for screenshots and shared logs.

If `$ARGUMENTS` is shorter than 200 chars, render it in full (no `[full prompt at …]` suffix needed). If the user explicitly asks to see the full prompt header in the conversation ("show full prompt"), expand for that turn only — never make full-expansion the persistent default.

---

## Step 1 — Initial plan (Claude)

Delegate the plan to the `Plan` agent (`subagent_type: "Plan"`). Pass the feature spec verbatim plus this constraint:

> Output a numbered implementation plan with: files to touch, function-level changes, schema migrations (if any), test plan, and risk list. No prose outside the plan. **Hard cap: 800 words.** Respect the project's `CLAUDE.md` if present.

Write the result to `$RUN_DIR/plan.v1.md`. Initialize the round counter:

```bash
echo 1 > "$RUN_DIR/plan.round"
```

---

## Step 2 — Codex plan-review loop (score-gated, fully automatic)

Runs until **score > 8.5 AND BLOCKING list empty**, OR safety cap (6 rounds), OR Codex errors out. The loop's exit reason is written to `$RUN_DIR/plan.exit-reason`. The round counter (`$RUN_DIR/plan.round`) is incremented by the runtime model between iterations.

**Bash exit-code contract for the loop driver:** Step 2d returns `0` if the loop should end (with `plan.exit-reason` updated) or `100` if it should continue (refine pass, then re-enter Step 2a).

### 2a. Build the prompt file

```bash
source "$RUN_DIR/lib.sh"
N=$(cat "$RUN_DIR/plan.round")

{
  cat <<'PROMPT_HEAD'
Review this implementation plan. The project's CLAUDE.md (if it exists in the working directory) describes the codebase's architecture, conventions, and hard rules — read it first and verify the plan honors them. If CLAUDE.md is absent, do a best-effort review based on general engineering principles.

Output format (exactly this shape, in this order):
  Line 1: SCORE: X.X
        — a single decimal from 1.0 to 10.0 rating the plan's overall quality
          (correctness, completeness, risk-awareness, alignment with the project's
          documented rules, AND fidelity to the user's original request). Use the
          full range; 8.5 is the bar for "ready to implement". Don't grade on a curve.

          IF YOU ASSIGN A SCORE OF 8.5 OR LOWER, YOU MUST INCLUDE AT LEAST ONE
          BLOCKING item explaining the gap. A low score with no BLOCKING list
          forces a refine round with nothing concrete to fix — the orchestrator
          rejects this shape and will synthesize a generic BLOCKING item AND
          flag the round as malformed.

  Line 2: blank

  Line 3+: zero, one, or both of the following section headings, each followed
          by a numbered list of one-sentence problem + one-sentence fix:

    BLOCKING:   — issues that MUST be addressed. The orchestrator REQUIRES this
                  list to be empty for convergence; ANY item triggers a refine
                  round regardless of score. Use numbered items (1., 2., …) —
                  the parser also accepts -, *, + bullets, but numbered is canonical.

    ADVISORY:   — non-blocking polish or future-improvement suggestions.
                  Surfaced to the user but NEVER gates convergence.

  If both sections would be empty AND your score is > 8.5, write the literal
  token CLEAN on its own line instead of any heading.

Convergence rule the orchestrator enforces:
  score > 8.5  AND  BLOCKING list empty  →  READY for implementation
  anything else                          →  refine and re-review (up to 6 rounds)

Feature spec (the user's original request — this is what the plan must implement):
---
PROMPT_HEAD
  cat "$RUN_DIR/prompt.md"
  cat <<'PROMPT_TAIL'

Plan to review:
---
PROMPT_TAIL
  cat "$RUN_DIR/plan.v${N}.md"
} > "$RUN_DIR/prompt.review.v${N}.txt"
```

### 2b. Run Codex

Foreground Bash with `timeout: 600000` on the **harness Bash tool call**. The shell-level `with_timeout` (from `lib.sh`) provides the same guarantee for standalone CLI use. Prompt is piped via stdin (`-` positional) to avoid argv-length truncation.

```bash
source "$RUN_DIR/lib.sh"
TIMEOUT_BIN=$(cat "$RUN_DIR/timeout-bin")
N=$(cat "$RUN_DIR/plan.round")

with_timeout 600 codex exec \
  --skip-git-repo-check \
  -s read-only \
  -c model="gpt-5.2" \
  -c model_reasoning_effort="xhigh" \
  --json \
  --output-last-message "$RUN_DIR/review.v${N}.md" \
  - \
  < "$RUN_DIR/prompt.review.v${N}.txt" \
  > "$RUN_DIR/codex.v${N}.jsonl" 2>&1
echo "$?" > "$RUN_DIR/codex.v${N}.rc"
```

Notes on flags: `--skip-git-repo-check` lets Codex run with the scratch dir; `gpt-5.2` at `xhigh` reasoning is the standard reviewer pairing for both plan and diff reviews; `-s read-only` keeps Codex inside the non-interactive sandbox; `--output-last-message` writes Codex's final turn; `--json` streams events; `-` reads the prompt from stdin.

### 2c. Render the CODEX RESPONSE banner — ALWAYS, even on session error

The runtime model MUST render this banner BEFORE the convergence-check Bash. On a session error (empty/missing review file), render `verdict: EMPTY` with a one-line error body.

After every Codex call, the runtime model MUST:

1. `Read` `$RUN_DIR/review.v${N}.md` (line 1 is `SCORE: X.X`; remainder is `CLEAN` or `BLOCKING:` / `ADVISORY:` sections) and `$RUN_DIR/codex.v${N}.jsonl` (extract the `turn.completed` `usage` block).
2. Extract the score from line 1 to populate the banner's `score:` field. Classify:
   - `PASS`   — score > 8.5 AND zero `BLOCKING:` items (per the robust counter).
   - `REFINE` — score ≤ 8.5 OR ≥ 1 BLOCKING item.
   - `EMPTY`  — review file missing/empty.
3. Emit this block in the TEXT reply, with the heavy ═ rules verbatim:

   ````
   ═══════════════════════════════════════════════════════════════
   🤖 CODEX RESPONSE · round {N} · score: {X.X}/10 · verdict: {PASS | REFINE | EMPTY}
   ═══════════════════════════════════════════════════════════════

   ```text
   <verbatim contents of review.v{N}.md — every line, unedited.
    If the file is empty/missing, write instead the single line:
       (codex session error — see $RUN_DIR/codex.v{N}.jsonl tail for cause)>
   ```

   `tokens · in=… out=… total=…`  (or `tokens · unavailable` on session error)

   ═══════════════════════════════════════════════════════════════
   END CODEX RESPONSE · round {N}
   ═══════════════════════════════════════════════════════════════
   ````

4. Then run the convergence-check Bash below.

If a Claude refine pass happens in the same turn, introduce it with its own header:

   ```
   ───────────────────────────────────────────────────────────────
   ✏️ CLAUDE refine pass · round {N+1}
   ───────────────────────────────────────────────────────────────
   ```

### 2d. Convergence check + malformed-review enforcement + iteration logging

```bash
source "$RUN_DIR/lib.sh"
N=$(cat "$RUN_DIR/plan.round")
SCORE_TARGET=$(cat "$RUN_DIR/score-target")
MAX_ROUNDS=$(cat "$RUN_DIR/max-rounds")
CODEX_RC=$(cat "$RUN_DIR/codex.v${N}.rc")

# Session-error path — record and exit gracefully.
if [ "$CODEX_RC" -ne 0 ] || [ ! -s "$RUN_DIR/review.v${N}.md" ]; then
  echo "Codex round $N session error (rc=$CODEX_RC, file empty or missing)."
  tail -20 "$RUN_DIR/codex.v${N}.jsonl"
  printf '%s\t%s\t%s\t%s\tSESSION_ERROR\n' "$N" "0.0" "0" "0" >> "$RUN_DIR/plan-iterations.tsv"
  echo "session_error" > "$RUN_DIR/plan.exit-reason"
  cp "$RUN_DIR/plan.v${N}.md" "$RUN_DIR/plan.final.md"
  exit 0
fi

# Parse score.
SCORE=$(grep -E '^SCORE:' "$RUN_DIR/review.v${N}.md" | head -1 | sed -E 's/^SCORE:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/')
[ -z "$SCORE" ] && { SCORE=0; echo "WARNING: no SCORE line in round $N — treating as 0."; }

BLOCKING_COUNT=$(blocking_count_robust "$RUN_DIR/review.v${N}.md")
ADVISORY_COUNT=$(advisory_count_robust "$RUN_DIR/review.v${N}.md")
ROUND_STATUS="OK"

# Malformed-review enforcement: low score with no BLOCKING items is a Codex
# contract violation. Synthesize a generic BLOCKING item AND flag the round.
if ! awk "BEGIN { exit !($SCORE > $SCORE_TARGET) }" && [ "$BLOCKING_COUNT" -eq 0 ]; then
  echo "WARNING: Round $N malformed (score=$SCORE ≤ $SCORE_TARGET but BLOCKING list empty). Synthesizing a generic BLOCKING item."
  cat >> "$RUN_DIR/review.v${N}.md" <<SYNTH

---
ORCHESTRATOR-SYNTHESIZED (Codex contract violation: low score with no BLOCKING):
BLOCKING:
1. Codex scored this $SCORE/10 but provided no actionable items. Refiner: do a second-pass critique focused on the most-common gaps for a sub-8.5 plan — correctness, completeness, alignment with CLAUDE.md, fidelity to the user's spec — and revise accordingly.
SYNTH
  BLOCKING_COUNT=$(blocking_count_robust "$RUN_DIR/review.v${N}.md")
  ROUND_STATUS="MALFORMED"
fi

printf '%s\t%s\t%s\t%s\t%s\n' "$N" "$SCORE" "$BLOCKING_COUNT" "$ADVISORY_COUNT" "$ROUND_STATUS" >> "$RUN_DIR/plan-iterations.tsv"
echo "Round $N: score=$SCORE / $SCORE_TARGET, BLOCKING=$BLOCKING_COUNT, ADVISORY=$ADVISORY_COUNT, status=$ROUND_STATUS"

# Convergence.
if awk "BEGIN { exit !($SCORE > $SCORE_TARGET) }" && [ "$BLOCKING_COUNT" -eq 0 ]; then
  echo "Plan converged at round $N (score $SCORE > $SCORE_TARGET, 0 BLOCKING)"
  cp "$RUN_DIR/plan.v${N}.md" "$RUN_DIR/plan.final.md"
  echo "converged" > "$RUN_DIR/plan.exit-reason"
  exit 0
fi

# Safety cap.
if [ "$N" -ge "$MAX_ROUNDS" ]; then
  echo "Safety cap hit ($MAX_ROUNDS rounds; final score $SCORE, $BLOCKING_COUNT BLOCKING)."
  cp "$RUN_DIR/plan.v${N}.md" "$RUN_DIR/plan.final.md"
  echo "cap" > "$RUN_DIR/plan.exit-reason"
  exit 0
fi

exit 100
```

### 2e. Refine pass (Bash exit code 100)

Delegate to the `Plan` agent:

> Refine the plan to address every BLOCKING item (including any `ORCHESTRATOR-SYNTHESIZED` items appended after a `---` divider). ADVISORY items are optional polish — apply only if low-cost. Output the full revised plan, not a diff. Respect the project's `CLAUDE.md` if present.
>
> Feature spec: \<paste `$RUN_DIR/prompt.md`\>
>
> Current plan: \<paste `$RUN_DIR/plan.v${N}.md`\>
>
> Codex review: \<paste `$RUN_DIR/review.v${N}.md`\>

After the refiner returns:

```bash
N=$(cat "$RUN_DIR/plan.round")
# (refiner has written plan.v$((N+1)).md)
echo $((N + 1)) > "$RUN_DIR/plan.round"
```

Then re-enter Step 2a.

### 2f. Loop exit — render the iteration table

```bash
source "$RUN_DIR/lib.sh"
SCORE_TARGET=$(cat "$RUN_DIR/score-target")
{
  echo "| Round | Score | BLOCKING | ADVISORY | Status            |"
  echo "|-------|-------|----------|----------|-------------------|"
  while IFS=$'\t' read -r n score blocking advisory status; do
    if [ "$status" = "SESSION_ERROR" ]; then
      verdict="SESSION_ERROR"
    elif [ "$status" = "MALFORMED" ]; then
      verdict="REFINE (malformed)"
    elif awk "BEGIN { exit !($score > $SCORE_TARGET) }" && [ "$blocking" -eq 0 ]; then
      verdict="PASS ✓"
    else
      verdict="REFINE"
    fi
    echo "| $n | $score | $blocking | $advisory | $verdict |"
  done < "$RUN_DIR/plan-iterations.tsv"
} > "$RUN_DIR/plan-iterations.md"
```

The runtime model MUST `Read` `$RUN_DIR/plan-iterations.md` and emit its contents verbatim under `### Plan loop — iteration table`. If `plan.exit-reason == session_error`, also surface: `⚠ Plan loop exited on Codex session error at round N — skipping implementation. Re-run /claudex to retry.`

---

## Step 3 — Implement (Claude, delegated)

**Skip Step 3 entirely if `plan.exit-reason == session_error`** — implementing against an unreviewed plan would burn a Codex round on a diff that may not match user intent. Go straight to Step 6.

```bash
PLAN_EXIT_REASON=$(cat "$RUN_DIR/plan.exit-reason")
if [ "$PLAN_EXIT_REASON" = "session_error" ]; then
  echo "skipped_plan_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi
```

Otherwise (`converged` or `cap`), route the implementation according to the project's `CLAUDE.md` routing rules. Typical patterns:

- **Per-component specialist agent** — if CLAUDE.md defines specialist agents, delegate to the matching one.
- **Project-orchestrator agent** — if CLAUDE.md defines an orchestrator for multi-component changes, use it when the plan touches ≥ 2 components.
- **Main thread** — for shared/cross-cutting code or projects without specialist agents.

If CLAUDE.md is absent or silent on routing, default to the main thread.

Pass to the implementer:
- The verbatim user prompt (`$RUN_DIR/prompt.md`) as the north-star spec.
- `$RUN_DIR/plan.final.md` as the implementation roadmap.
- Remaining unresolved BLOCKING items from Step 2 (if `plan.exit-reason == cap`) as extra constraints.
- A `--commit` directive: "Commit the result on the current branch as a single commit. Subject: use the project's commit convention (e.g. conventional-commits `feat(<scope>): …` if applicable; otherwise an imperative one-line subject). Body: bullet points from the plan."

**Before** delegating, capture the current HEAD as the base SHA:

```bash
git rev-parse HEAD > "$RUN_DIR/base.sha"
```

**After** delegation returns, verify three things: the delegate committed; no NEW dirt since preflight; no pre-existing dirty PATH was folded into the commit.

```bash
source "$RUN_DIR/lib.sh"
BASE_SHA=$(cat "$RUN_DIR/base.sha")
NEW_HEAD=$(git rev-parse HEAD)

# Check 1: HEAD changed (delegate actually committed).
if [ "$NEW_HEAD" = "$BASE_SHA" ]; then
  echo "ERROR: Implementer returned without creating any commit (HEAD unchanged from base). Aborting."
  echo "delegate_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

# Check 2: no NEW non-scratch dirt since preflight (delta against baseline-dirt.txt).
CURRENT_DIRT=$(git status --porcelain | grep -Ev '^\?\? \.claude/claudex/' | LC_ALL=C sort -u || true)
NEW_DIRT=$(comm -13 "$RUN_DIR/baseline-dirt.txt" <(printf '%s\n' "$CURRENT_DIRT") | grep -v '^$' || true)
if [ -n "$NEW_DIRT" ]; then
  echo "ERROR: Implementer left NEW uncommitted non-scratch changes since /claudex started:"
  echo "$NEW_DIRT"
  echo "delegate_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

# Check 3: no pre-existing dirty PATH was folded into the feature commit.
#         baseline_paths() reads $RUN_DIR/baseline-dirt.txt and extracts the
#         file paths. comm -12 returns the intersection with committed paths.
COMMITTED_PATHS=$(git diff --name-only -z "$BASE_SHA..HEAD" | tr '\0' '\n' | grep -v '^$' | LC_ALL=C sort -u)
LEAKED=$(comm -12 <(baseline_paths) <(printf '%s\n' "$COMMITTED_PATHS") | grep -v '^$' || true)
if [ -n "$LEAKED" ]; then
  echo "ERROR: Pre-existing dirty files were folded into the feature commit, mixing WIP with the implementation:"
  echo "$LEAKED"
  echo "(Pre-existing dirt was snapshotted to $RUN_DIR/baseline-dirt.txt at preflight; those paths are off-limits to delegated commits.)"
  echo "delegate_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

git rev-parse HEAD > "$RUN_DIR/impl.sha"
git diff "$BASE_SHA..HEAD" > "$RUN_DIR/impl.v1.diff"
echo 1 > "$RUN_DIR/impl.round"
```

The base-SHA + cumulative-diff pattern works whether the implementer produced one commit or many.

---

## Step 4 — Codex diff-review loop (score-gated, fully automatic)

Mirrors Step 2: each round Codex scores the cumulative diff. Loop exits on convergence, safety cap, session error, or fix-pass delegate error.

### 4a. Recompute the cumulative diff and build the prompt file

```bash
source "$RUN_DIR/lib.sh"
M=$(cat "$RUN_DIR/impl.round")
BASE_SHA=$(cat "$RUN_DIR/base.sha")
git diff "$BASE_SHA..HEAD" > "$RUN_DIR/impl.v${M}.diff"

{
  cat <<'PROMPT_HEAD'
Review this git diff against the plan it was supposed to implement. The project's CLAUDE.md (if it exists in the working directory) describes the codebase's architectural rules and conventions — read it first and verify the diff doesn't violate them.

Output format (exactly this shape, in this order):
  Line 1: SCORE: X.X
        — a single decimal from 1.0 to 10.0 rating the implementation's quality
          (correctness, security, faithfulness to the plan AND the user's original
          request, code clarity, compliance with the project's documented rules).
          Use the full range; 8.5 is the bar for "ship this". Don't grade on a curve.

          IF YOU ASSIGN A SCORE OF 8.5 OR LOWER, YOU MUST INCLUDE AT LEAST ONE
          BLOCKING item explaining the gap. A low score with no BLOCKING list
          forces a fix-pass round with nothing concrete to fix — the orchestrator
          will synthesize one and flag the round as malformed.

  Line 2: blank

  Line 3+: zero, one, or both of:
    BLOCKING:   — issues that MUST be fixed before ship. One-sentence problem
                  + one-sentence fix per item. Convergence REQUIRES this list
                  empty. Numbered (1., 2., …) is canonical; -, *, + bullets
                  also accepted by the parser.
    ADVISORY:   — non-blocking polish or future-improvement notes.

  Write CLEAN on its own line if both sections would be empty AND your score is > 8.5.

Convergence rule the orchestrator enforces:
  score > 8.5  AND  BLOCKING list empty  →  READY to ship
  anything else                          →  fix-pass and re-review (up to 6 rounds)

Feature spec (the user's original request — the diff must satisfy this):
---
PROMPT_HEAD
  cat "$RUN_DIR/prompt.md"
  cat <<'PROMPT_MID'

Plan the diff was meant to implement:
---
PROMPT_MID
  cat "$RUN_DIR/plan.final.md"
  cat <<'PROMPT_TAIL'

Diff to review (cumulative from base SHA — includes the initial implementation plus every fix-pass commit so far):
---
PROMPT_TAIL
  cat "$RUN_DIR/impl.v${M}.diff"
} > "$RUN_DIR/prompt.review.diff.v${M}.txt"
```

### 4b. Run Codex

```bash
source "$RUN_DIR/lib.sh"
TIMEOUT_BIN=$(cat "$RUN_DIR/timeout-bin")
M=$(cat "$RUN_DIR/impl.round")

with_timeout 600 codex exec \
  --skip-git-repo-check \
  -s read-only \
  -c model="gpt-5.2" \
  -c model_reasoning_effort="xhigh" \
  --json \
  --output-last-message "$RUN_DIR/review.diff.v${M}.md" \
  - \
  < "$RUN_DIR/prompt.review.diff.v${M}.txt" \
  > "$RUN_DIR/codex.diff.v${M}.jsonl" 2>&1
echo "$?" > "$RUN_DIR/codex.diff.v${M}.rc"
```

### 4c. Render the CODEX RESPONSE banner — ALWAYS, even on session error

Same banner format as Step 2c — substitute `round diff/M` for `round {N}`. Render before the convergence-check Bash, even on `EMPTY` verdict.

### 4d. Convergence check + malformed-review enforcement + iteration logging

```bash
source "$RUN_DIR/lib.sh"
M=$(cat "$RUN_DIR/impl.round")
BASE_SHA=$(cat "$RUN_DIR/base.sha")
SCORE_TARGET=$(cat "$RUN_DIR/score-target")
MAX_FIX_ROUNDS=$(cat "$RUN_DIR/max-fix-rounds")
CODEX_RC=$(cat "$RUN_DIR/codex.diff.v${M}.rc")

# Session-error path.
if [ "$CODEX_RC" -ne 0 ] || [ ! -s "$RUN_DIR/review.diff.v${M}.md" ]; then
  echo "Codex diff review round $M session error (rc=$CODEX_RC, file empty or missing)."
  tail -20 "$RUN_DIR/codex.diff.v${M}.jsonl"
  CURRENT_SHA=$(git rev-parse HEAD)
  printf '%s\t%s\t%s\t+%s/-%s\t%s\t%s\t%s\tSESSION_ERROR\n' \
    "$M" "0.0" "0" "0" "0" "$CURRENT_SHA" "0" "0" \
    >> "$RUN_DIR/impl-iterations.tsv"
  echo "session_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

# Parse score + counts.
SCORE=$(grep -E '^SCORE:' "$RUN_DIR/review.diff.v${M}.md" | head -1 | sed -E 's/^SCORE:[[:space:]]*([0-9]+(\.[0-9]+)?).*/\1/')
[ -z "$SCORE" ] && { SCORE=0; echo "WARNING: no SCORE line in diff round $M — treating as 0."; }
BLOCKING_COUNT=$(blocking_count_robust "$RUN_DIR/review.diff.v${M}.md")
ADVISORY_COUNT=$(advisory_count_robust "$RUN_DIR/review.diff.v${M}.md")
ROUND_STATUS="OK"

# Malformed-review enforcement.
if ! awk "BEGIN { exit !($SCORE > $SCORE_TARGET) }" && [ "$BLOCKING_COUNT" -eq 0 ]; then
  echo "WARNING: Diff round $M malformed (score=$SCORE ≤ $SCORE_TARGET but BLOCKING list empty). Synthesizing a generic BLOCKING item."
  cat >> "$RUN_DIR/review.diff.v${M}.md" <<SYNTH

---
ORCHESTRATOR-SYNTHESIZED (Codex contract violation: low score with no BLOCKING):
BLOCKING:
1. Codex scored this diff $SCORE/10 but provided no actionable items. Fixer: do a second-pass review of the cumulative diff focused on correctness, alignment with CLAUDE.md, and fidelity to the user's spec; commit fixes for the most likely gaps.
SYNTH
  BLOCKING_COUNT=$(blocking_count_robust "$RUN_DIR/review.diff.v${M}.md")
  ROUND_STATUS="MALFORMED"
fi

# Delta-change for the table.
if [ "$M" -eq 1 ]; then
  PRIOR_SHA="$BASE_SHA"
else
  PRIOR_SHA=$(awk -F'\t' '$NF != "SESSION_ERROR" { sha=$5 } END { print sha }' "$RUN_DIR/impl-iterations.tsv")
  [ -z "$PRIOR_SHA" ] && PRIOR_SHA="$BASE_SHA"
fi
CURRENT_SHA=$(git rev-parse HEAD)
SHORTSTAT=$(git diff --shortstat "$PRIOR_SHA..$CURRENT_SHA")
FILES=$(echo "$SHORTSTAT" | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo 0)
INS=$(echo   "$SHORTSTAT" | grep -oE '[0-9]+ insertions?\(\+\)' | grep -oE '[0-9]+' || echo 0)
DEL=$(echo   "$SHORTSTAT" | grep -oE '[0-9]+ deletions?\(-\)'   | grep -oE '[0-9]+' || echo 0)

printf '%s\t%s\t%s\t+%s/-%s\t%s\t%s\t%s\t%s\n' \
  "$M" "$SCORE" "${FILES:-0}" "${INS:-0}" "${DEL:-0}" "$CURRENT_SHA" "$BLOCKING_COUNT" "$ADVISORY_COUNT" "$ROUND_STATUS" \
  >> "$RUN_DIR/impl-iterations.tsv"
echo "Diff round $M: score=$SCORE / $SCORE_TARGET, files=${FILES:-0}, lines=+${INS:-0}/-${DEL:-0}, BLOCKING=$BLOCKING_COUNT, ADVISORY=$ADVISORY_COUNT, status=$ROUND_STATUS"

if awk "BEGIN { exit !($SCORE > $SCORE_TARGET) }" && [ "$BLOCKING_COUNT" -eq 0 ]; then
  echo "Implementation converged at diff round $M (score $SCORE > $SCORE_TARGET, 0 BLOCKING)"
  echo "$SCORE" > "$RUN_DIR/impl.final-score"
  echo "converged" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

if [ "$M" -ge "$MAX_FIX_ROUNDS" ]; then
  echo "Safety cap hit ($MAX_FIX_ROUNDS diff rounds; final score $SCORE, $BLOCKING_COUNT BLOCKING)."
  echo "$SCORE" > "$RUN_DIR/impl.final-score"
  echo "cap" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

exit 100
```

### 4e. Loop exit — render the iteration table

```bash
source "$RUN_DIR/lib.sh"
SCORE_TARGET=$(cat "$RUN_DIR/score-target")
{
  echo "| Round | Score | Files | Lines Δ   | BLOCKING | ADVISORY | Status            |"
  echo "|-------|-------|-------|-----------|----------|----------|-------------------|"
  while IFS=$'\t' read -r m score files linesdelta sha blocking advisory status; do
    if [ "$status" = "SESSION_ERROR" ]; then
      verdict="SESSION_ERROR"
    elif [ "$status" = "MALFORMED" ]; then
      verdict="REFINE (malformed)"
    elif awk "BEGIN { exit !($score > $SCORE_TARGET) }" && [ "$blocking" -eq 0 ]; then
      verdict="PASS ✓"
    else
      verdict="REFINE"
    fi
    echo "| $m | $score | $files | $linesdelta | $blocking | $advisory | $verdict |"
  done < "$RUN_DIR/impl-iterations.tsv"
} > "$RUN_DIR/impl-iterations.md"
```

The runtime model MUST `Read` `$RUN_DIR/impl-iterations.md` and emit its contents verbatim under `### Implementation loop — iteration table`. Surface exit-reason callouts (Step 6) immediately after.

---

## Step 5 — Fix-pass subroutine (per-round, called when Step 4d exits with code 100)

Invoked when the diff isn't ready AND the safety cap hasn't fired AND no session error. Delegates to the **same agent that did Step 3**.

Pass to the agent:
- The verbatim user prompt (`$RUN_DIR/prompt.md`).
- The verbatim BLOCKING list from `$RUN_DIR/review.diff.v${M}.md` (including any `ORCHESTRATOR-SYNTHESIZED` items appended after a `---` divider).
- The verbatim ADVISORY list (optional polish).
- The current cumulative diff at `$RUN_DIR/impl.v${M}.diff`.
- A `--commit` directive: "Address every BLOCKING item. Commit as a single follow-up. Subject: a one-line fix-pass summary using the project's commit convention (e.g. `fixup(<scope>): address Codex review (round M)`). Body: bullet points naming each BLOCKING item resolved."

After the delegated agent returns, verify three things: no NEW dirt since preflight; HEAD moved; no pre-existing dirty path was folded into the new commit. Any failure → `delegate_error`, stop.

```bash
source "$RUN_DIR/lib.sh"
M=$(cat "$RUN_DIR/impl.round")

# Check 1: no NEW dirt since preflight. (Comes before HEAD-change because
# uncommitted-but-modified files would otherwise be invisible to the next
# `git diff base..HEAD` review — the loop would re-review the same diff.)
CURRENT_DIRT=$(git status --porcelain | grep -Ev '^\?\? \.claude/claudex/' | LC_ALL=C sort -u || true)
NEW_DIRT=$(comm -13 "$RUN_DIR/baseline-dirt.txt" <(printf '%s\n' "$CURRENT_DIRT") | grep -v '^$' || true)
if [ -n "$NEW_DIRT" ]; then
  echo "ERROR: Fix-pass round $M left NEW uncommitted non-scratch changes since preflight:"
  echo "$NEW_DIRT"
  echo "delegate_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

# Check 2: HEAD changed (fixer actually committed).
PREV_HEAD=$(awk -F'\t' '$NF != "SESSION_ERROR" { sha=$5 } END { print sha }' "$RUN_DIR/impl-iterations.tsv")
[ -z "$PREV_HEAD" ] && PREV_HEAD=$(cat "$RUN_DIR/impl.sha")
NEW_HEAD=$(git rev-parse HEAD)
if [ "$NEW_HEAD" = "$PREV_HEAD" ]; then
  echo "ERROR: Fix-pass round $M did not create a new commit (HEAD unchanged, tree clean). Process error. Stopping."
  echo "delegate_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

# Check 3: no pre-existing dirty PATH was folded into the new commit.
COMMITTED_THIS_ROUND=$(git diff --name-only -z "$PREV_HEAD..$NEW_HEAD" | tr '\0' '\n' | grep -v '^$' | LC_ALL=C sort -u)
LEAKED=$(comm -12 <(baseline_paths) <(printf '%s\n' "$COMMITTED_THIS_ROUND") | grep -v '^$' || true)
if [ -n "$LEAKED" ]; then
  echo "ERROR: Fix-pass round $M folded pre-existing dirty files into its commit:"
  echo "$LEAKED"
  echo "(Pre-existing dirt was snapshotted to $RUN_DIR/baseline-dirt.txt at preflight; those paths are off-limits.)"
  echo "delegate_error" > "$RUN_DIR/impl.exit-reason"
  exit 0
fi

# Healthy: no new dirt + HEAD moved + no path leak. Record and continue.
echo "$NEW_HEAD" >> "$RUN_DIR/fixup.shas"
echo $((M + 1)) > "$RUN_DIR/impl.round"
exit 100
```

---

## Step 6 — Report

Print a summary to the user with:

- **Plan loop**: rounds run, final Codex score, exit reason from `$RUN_DIR/plan.exit-reason`. Inline the plan-iterations table verbatim under `### Plan loop — iterations`. Note any `MALFORMED` rounds.
- **Implementation loop**: rounds run, final Codex score, exit reason from `$RUN_DIR/impl.exit-reason`. Inline `$RUN_DIR/impl-iterations.md` if present.
- **Commits created** (SHAs + subjects): `$RUN_DIR/impl.sha` + every line of `$RUN_DIR/fixup.shas`.
- **Exit-reason callouts** (one line each, mandatory):
  - Plan `converged`        → `✅ Plan green-lit at round N with score X.X.`
  - Plan `cap`              → `⚠ Plan safety cap fired after N rounds — X residual BLOCKING items carried into implementation.`
  - Plan `session_error`    → `⚠ Plan loop exited on Codex session error at round N — implementation skipped. Re-run /claudex to retry.`
  - Impl `converged`        → `✅ Codex green-lit the implementation at round M with score X.X.`
  - Impl `cap`              → `⚠ Implementation safety cap fired after M rounds — X residual BLOCKING items remain.`
  - Impl `session_error`    → `⚠ Codex session error in implementation review at round M — loop stopped gracefully, HEAD preserved. Re-run /claudex to resume.`
  - Impl `delegate_error`   → `❌ Implementation loop stopped on delegate process error at round M (no commit, new uncommitted dirt, or pre-existing dirty path folded into the commit). Inspect the working tree.`
  - Impl `skipped_plan_error` → `⊘ Implementation skipped because the plan was never reviewed (plan session error).`
- **Privacy reminder**: `Artifacts under $RUN_DIR contain your prompt, Codex prompts + responses, diffs, and JSONL streams. \`rm -rf $RUN_DIR\` to dispose; otherwise consider a periodic prune.`
- **Paper trail**: list `$RUN_DIR` and its contents.

End with: "Review the commits and squash/amend if you want a tighter history."

---

## Notes for the runtime model executing this command

- **Bash snippet convention.** Every Bash snippet below Step 0 assumes `$RUN_DIR` is set by the runtime model — prefix each Bash tool call with `RUN_DIR=<literal path from Step 0b>`. The `.claude/claudex/latest-run` pointer file is a human convenience only; the skill does not read it. This makes parallel `/claudex` runs in separate chats safe (each chat threads its own `$RUN_DIR`).
- **Do not skip the preflight.** Both the binary check AND the smoke probe must pass. The smoke probe is what catches an expired Codex session.
- **Render the banner BEFORE the convergence-check Bash, always.** Even on session error — emit `verdict: EMPTY` with a one-line session-error body.
- **BLOCKING means MUST-FIX, mechanically.** Convergence requires `score > 8.5` AND `BLOCKING_COUNT == 0`. ADVISORY items never block. `blocking_count_robust` (in `lib.sh`) handles numbered, bulleted, and plain-text BLOCKING items; if the heading is present but no items parse, it falls back to "non-empty body lines under BLOCKING" and prints a parser warning. A score ≤ 8.5 with zero BLOCKING is treated as a Codex contract violation: the orchestrator appends an `ORCHESTRATOR-SYNTHESIZED BLOCKING:` block and flags the round `MALFORMED`.
- **State lives in files under `$RUN_DIR`.** Read `score-target`, `plan.exit-reason`, `impl.exit-reason`, `plan.round`, `impl.round`, `max-rounds`, `max-fix-rounds`, `timeout-bin`, `baseline-dirt.txt` from their files at the top of every snippet that needs them. The exit-reason files are the single source of truth for "how did this loop end."
- **Bash exit codes drive the loop.** Convergence Bash returns `0` when the loop should end (with `*.exit-reason` updated) and `100` when it should continue. Other non-zero codes are real errors.
- **Shared shell helpers live in `$RUN_DIR/lib.sh`** (`with_timeout`, `blocking_count_robust`, `advisory_count_robust`, `baseline_paths`). `source "$RUN_DIR/lib.sh"` at the top of any snippet that needs them. The library is written once at Step 0g and is portable across bash and zsh.
- **Session-token resilience.** Empty / non-zero-RC Codex calls are recorded as `SESSION_ERROR` in the iterations log and the matching `*.exit-reason` file. The loop exits cleanly — no `exit 1`, no hang. Plan-loop session error skips Step 3+; impl-loop session error keeps HEAD intact and exits to the report.
- **Dirty-tree handling is delta + path-set based.** Preflight (Step 0i) snapshots existing dirt to `baseline-dirt.txt`. Post-delegate checks (Steps 3 + 5) reject (a) **new** dirt since the snapshot, AND (b) any **pre-existing dirty path** that the delegate committed (paths in `baseline-dirt.txt` are off-limits to delegated commits — they protect the user's WIP from being silently mixed into the feature commit).
- **Portable timeouts.** `with_timeout` in `lib.sh` uses explicit `if [ -n "$TIMEOUT_BIN" ]; then "$TIMEOUT_BIN" "$secs" "$@"; else "$@"; fi` so it works under bash AND zsh. (Parameter-expansion word-splitting is on in bash and off by default in zsh, so the `${VAR:+…}` idiom breaks under zsh.) The harness Bash-tool `timeout:` parameter is the primary mechanism; the shell-level `with_timeout` is the parity for standalone CLI use.
- **Provider quota.** Each Codex round consumes the user's Codex-provider quota; each Claude refine/fix round consumes the user's Claude-provider quota. The score-gated termination is automatic; safety caps (6 rounds per loop) ARE binding.
- **Network surface.** Artifacts written to `.claude/claudex/` are local. Model invocations (both Codex AND Claude) send the relevant prompts + code + diffs to their respective providers over the network. Privacy and retention policies of both providers apply.
- **Post-delegate verification (Steps 3 + 5).** Three checks per delegation: (a) **HEAD moved** (something was committed), (b) **no NEW dirt** since preflight, (c) **no pre-existing dirty path folded into the commit**. Failure of any → `impl.exit-reason=delegate_error`, stop.
- **Project rules live in `CLAUDE.md`.** Architectural rules, conventions, routing of work to specialist agents, commit-message formats — all deferred to the project's `CLAUDE.md`. Codex is instructed to read it; the implementer/refiner/fixer agents should already follow it.
- **If Codex disagrees with `CLAUDE.md`,** the project's `CLAUDE.md` wins. Surface the conflict to the user.
- **Worktree state.** Implementation runs on the current branch by default. If the user is on the trunk branch (e.g. `main` / `master`), ask before committing.
