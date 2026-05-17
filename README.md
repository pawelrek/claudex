# Claudex

Claudex is a Claude + Codex cross-review workflow for shipping code changes with less copy-paste and more discipline.

Claude plans and implements. Codex reviews and scores. Claudex keeps the loop moving until the plan or implementation is good enough to ship, or until a safety cap stops the run and surfaces what remains.

```text
Feature spec
   |
   v
Claude plans  ->  Codex reviews plan  ->  refine until ready
   |
   v
Claude implements  ->  Codex reviews diff  ->  fix until ready
   |
   v
Report, commits, iteration tables, paper trail
```

## What It Does

- Runs a score-gated plan review loop.
- Runs a score-gated implementation review loop.
- Uses Codex as an independent reviewer for plans and diffs.
- Treats `BLOCKING` review items as mechanically must-fix.
- Allows `ADVISORY` items without blocking convergence.
- Preserves every prompt, plan revision, Codex response, JSONL stream, diff, score, and iteration table.
- Handles Codex session failures without hanging.
- Protects existing working-tree changes from being silently mixed into generated commits.
- Truncates persistent prompt headers by default to reduce screenshot/log leakage.

## Requirements

- Claude Code with custom slash commands.
- Codex CLI installed and logged in.
- A Git repository with a valid `HEAD` commit.
- Optional but recommended: a project `CLAUDE.md` describing architecture, conventions, routing rules, and commit style.

Install Codex CLI if needed:

```bash
npm install -g @openai/codex
codex login
```

## Installation

Copy the command file into your Claude Code commands directory:

```text
.claude/commands/claudex.md
```

Make sure Claudex run artifacts are ignored:

```gitignore
.claude/claudex/
```

If you keep project commands in Git, commit only the command file, not the generated `.claude/claudex/<timestamp>/` run directories.

## Usage

Invoke Claudex from Claude Code:

```text
/claudex Add a searchable activity-log page with server-side filters, pagination, and a small UI for saved views.
```

For larger work, pass a full paragraph or detailed feature spec:

```text
/claudex <feature description>
```

If the feature description is empty, Claudex asks for a one-paragraph spec before starting.

## Review Contract

Codex must return this shape for each review:

```text
SCORE: 8.7

BLOCKING:
1. Problem sentence. Fix sentence.

ADVISORY:
1. Optional polish note. Suggested improvement.
```

The loop converges only when:

```text
score > 8.5 AND BLOCKING list is empty
```

`ADVISORY` items are shown to the user but never block convergence.

If Codex returns a score of `8.5` or lower with no `BLOCKING` items, Claudex treats that as a malformed review, appends a clearly marked synthetic blocking item, and continues the loop with a concrete fix/refine target.

## Workflow

### 1. Preflight

Claudex checks that:

- the current directory is inside a Git work tree,
- `HEAD` is valid,
- the Codex CLI exists,
- Codex can complete a tiny smoke probe,
- `.claude/claudex/` is gitignored,
- existing dirty files are snapshotted before any agent work starts.

### 2. Plan Loop

Claude creates a focused implementation plan. Codex reviews it for correctness, completeness, risk, project-rule compliance, and fidelity to the original request.

If Codex finds blocking issues, Claude refines the plan and the loop repeats.

### 3. Implementation

Claude implements the final plan according to the project's `CLAUDE.md` routing rules if present.

Claudex records the base SHA before implementation and verifies afterward that:

- a commit was created,
- no new uncommitted dirt was left behind,
- pre-existing dirty paths were not folded into the feature commit.

### 4. Diff Review Loop

Codex reviews the cumulative diff from the original base SHA to `HEAD`.

If Codex reports blocking issues, Claude applies a fix-pass commit, and Codex reviews the cumulative diff again.

### 5. Report

Claudex reports:

- plan-loop rounds and scores,
- implementation-loop rounds and scores,
- convergence/cap/session/delegate-error status,
- commits created,
- residual blocking items if any,
- the run artifact directory.

## Run Artifacts

Each run writes a timestamped paper trail:

```text
.claude/claudex/<timestamp>/
```

Typical contents:

```text
prompt.md
plan.v1.md
plan.final.md
review.v1.md
prompt.review.v1.txt
codex.v1.jsonl
impl.v1.diff
review.diff.v1.md
codex.diff.v1.jsonl
plan-iterations.tsv
plan-iterations.md
impl-iterations.tsv
impl-iterations.md
base.sha
impl.sha
fixup.shas
```

These artifacts are useful for auditing and debugging, but they may contain sensitive project data.

## Privacy Notes

Claudex artifacts are local files, but model calls still leave your machine:

- Claude planning/refinement/implementation prompts and tool context go to the configured Claude provider.
- Codex review prompts, plans, and diffs go to the configured Codex provider.

The generated run directory may include:

- original feature specs,
- code and diffs,
- stack traces,
- local paths,
- JSONL telemetry,
- model responses.

Prune old runs when they are no longer useful:

```bash
rm -rf .claude/claudex/<timestamp>/
```

Or clear all Claudex run artifacts:

```bash
rm -rf .claude/claudex/
```

## Safety Features

- Six-round cap for the plan loop.
- Six-round cap for the implementation loop.
- Read-only Codex sandbox for review calls.
- No sidecar polling loops that can hang forever.
- Prompt files are piped through stdin to avoid shell argument-length limits.
- Portable timeout wrapper for macOS/Linux.
- Session-error handling with visible `EMPTY` banners.
- Dirty-tree protection for user WIP.
- Truncated persistent prompt header to reduce accidental leakage in screenshots.

## Project Integration

Claudex is project-agnostic. It delegates project-specific behavior to `CLAUDE.md` when available.

Use `CLAUDE.md` to define:

- architecture rules,
- module boundaries,
- security constraints,
- specialist agent routing,
- test expectations,
- commit-message conventions.

Codex is instructed to read `CLAUDE.md` during review. If Codex disagrees with documented project rules, `CLAUDE.md` wins.

## Troubleshooting

**Codex smoke probe fails**

Run:

```bash
codex login
codex exec "Reply OK"
```

Also check provider quota, network access, and CLI installation.

**Run artifacts might be committed**

Add:

```gitignore
.claude/claudex/
```

Then verify:

```bash
git check-ignore -v .claude/claudex/probe-file
```

**Loop stops with `delegate_error`**

The implementer/fixer likely failed one of the commit hygiene checks:

- no commit was created,
- new uncommitted files were left behind,
- pre-existing dirty files were folded into the commit.

Inspect the working tree and the latest run directory.

**Codex returns a low score without blocking items**

Claudex marks the review as malformed, appends a synthetic blocking item, and continues. This prevents no-op refine/fix loops.

## Status

Claudex is intentionally conservative. It favors visible paper trails, explicit scoring, and bounded loops over silent automation.

The goal is not to replace human judgment. The goal is to make a Claude + Codex workflow repeatable, inspectable, and much less annoying to run.
