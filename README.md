# Claudex

Claudex is a cross-model review workflow for shipping code changes with less copy-paste and more discipline: Claude plans and implements, a **3-seat independent review panel** scores every round, and the main-thread model adjudicates each finding as final juror.

```text
Feature spec
   |
   v
Claude plans ──► ┌─ codex (GPT, external auditor)      ─┐
                 ├─ VULCAN (Sonnet, security, bottom-up)─┤──► JUROR (main thread)
                 └─ MERIDIAN (Sonnet, correctness,      ─┘      verifies findings,
                    top-down)                                    scores, gates
   |
   refine until juror score > 8.5 AND zero accepted BLOCKING
   v
Claude implements (delegated agent, never the main thread)
   |
   same panel reviews the cumulative diff, fix-pass rounds until it converges
   v
Executive summary, round-matrix tables, findings ledger, commits, paper trail
```

## Why a panel

Same-model review is demonstrably lenient — a Claude reviewer grading Claude-written code under-reports. Claudex counters this three ways:

- an **external seat** (Codex, newest GPT resolved at runtime from the CLI's model cache),
- **blinded personas**: reviewers are told the artifact comes from an unknown external contributor with a history of plausible-looking but subtly wrong work; they never see each other's reviews,
- a **juror** that verifies every BLOCKING/MAJOR claim against the actual artifact and dismisses anything unverifiable — reviewer credit depends on surviving adjudication.

The two Sonnet seats are deliberately differentiated so they don't collapse into one perspective: VULCAN hunts security defects bottom-up from untrusted inputs and dangerous sinks; MERIDIAN hunts correctness defects top-down from function contracts, simulating execution.

A fourth, **non-scoring EXECUTOR seat** runs the project's test suite every implementation-review round. Its exit codes gate convergence — a RED suite can never pass, regardless of reviewer scores — because a panel that only *reads* diffs will green-light code that doesn't *run*.

## Review contract

Every reviewer returns:

```text
SCORE: X.X

BLOCKING:   — must fix; any accepted item forces another round
MAJOR:      — weighs on score; expected fixed next round
MINOR:      — fix when cheap
POLISHING:  — cosmetic, never required
```

Convergence (both loops): **juror score > 8.5 AND the juror's accepted BLOCKING list is empty** — and in the diff loop, additionally an EXEC REPORT of `GREEN` or `NO_TESTS`: static review never replaces execution, so a red test suite can never converge regardless of reviewer scores. Safety cap: 20 rounds per loop. A round is valid on a quorum of ≥ 2 parseable reviews including codex. A reviewer scoring ≤ 8.5 with nothing actionable is flagged MALFORMED; an unsubstantiated "CLEAN" is discarded.

## Requirements

- Claude Code
- [Codex CLI](https://github.com/openai/codex) installed and logged in (`npm install -g @openai/codex && codex login`) — optional if you enable the Anthropic-only fallback
- `python3`, and a Git repository with a valid `HEAD`
- Optional but recommended: a project `CLAUDE.md` describing architecture rules, conventions, and commit style — reviewers read it and enforce it

## Installation

```bash
mkdir -p ~/.claude/skills/claudex
cp SKILL.md lib.sh ~/.claude/skills/claudex/
```

Make sure run artifacts are ignored in your projects:

```gitignore
.claude/claudex/
```

## Usage

```text
/claudex <feature description>   # full plan → review → implement → review run
/claudex resume                  # continue an interrupted run from its persisted round state
```

Interrupted runs (session limits, crashes, context loss) resume from the last completed artifact — finished rounds are never re-paid.

## Configuration — `.claudex.json` at the repo root (optional)

```json
{
  "allow_anthropic_only": true,
  "score_target": 8.5,
  "max_rounds": 20,
  "max_fix_rounds": 20,
  "test_command": "pytest -q",
  "executor_model": "sonnet"
}
```

`allow_anthropic_only` lets a run continue on the two Sonnet seats when Codex is unavailable (missing CLI, expired session, exhausted quota) — as loudly-flagged **DEGRADED** rounds recorded in the report, never silently. Off by default: the external seat is the design's main defense.

`test_command` pins exactly what the EXECUTOR runs (empty = auto-detect the project's runner). `executor_model` defaults to `sonnet`; `haiku` is a fine choice when `test_command` is pinned — the seat needs honest command execution and faithful reporting, not judgment.

## What you see while it runs

Each round emits a fixed round-matrix table (one row per round) plus a one-line blocker strip:

```text
🚧 OPEN BLOCKERS (round 3): ✅ no open blockers

| Rnd | codex | VULCAN | MERIDIAN | JUROR | Open B/M | Verdict |
|----:|------:|-------:|---------:|------:|:--------:|:-------:|
|  1  |  7.0  |  6.5   |   7.0    |  7.4  | 4B / 5M  | IMPROVE |
|  2  |  8.0  |  7.8   |   8.1    |  8.2  | 1B / 2M  | IMPROVE |
|  3  |  8.8  |  8.6   |   9.0    |  8.9  | 0B / 0M  | ✅ PASS |
```

The final report opens with an executive summary (outcome, open blockers/majors, rounds, commits, your next action), followed by the full tables, a run-wide deduped findings ledger (fix claims are verified against the diff, not trusted), per-seat hallucination stats, and the commit list.

## Safety features

- Implementation is always delegated to a separate agent — the juror never grades its own code.
- Commit hygiene checks: the implementer must commit; empty/net-zero commits are rejected; new uncommitted dirt is rejected; pre-existing dirty files folded into a commit are rejected; committed run artifacts are rejected (privacy backstop).
- Untrusted content (spec, plan, diff) is wrapped in per-round nonce fences so embedded text can't forge review verdicts.
- Codex calls run under a liveness watcher + wall-clock cap with one automatic reduced-scope retry.
- A repo-level heartbeat lock stops two concurrent runs from corrupting each other's commits.
- Preflight runs a behavioral self-test of the review parsers — a corrupted parser fails loudly instead of silently mis-gating convergence.
- Trunk protection: on main/master, Claudex pauses for explicit authorization before committing.

## Run artifacts and privacy

Each run writes a timestamped paper trail under `.claude/claudex/<timestamp>/`: the spec, every plan revision, every reviewer prompt and response, JSONL streams, diffs, juror verdicts, tables, and the findings ledger. Artifacts are local files, but model calls leave your machine: Codex calls go to OpenAI, Claude calls to Anthropic — both providers' data policies apply. Prune with `rm -rf .claude/claudex/`.

## Status

Claudex is intentionally conservative. It favors visible paper trails, explicit scoring, verified adjudication, and bounded loops over silent automation. The goal is not to replace human judgment — it's to make a multi-model review workflow repeatable, inspectable, and much less annoying to run.
