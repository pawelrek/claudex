---
name: claudex-code
description: "Lane-parallel implementation with Codex as the implementer. Sibling of /claudex, inverted: Codex implements AND reviews (one detached process per lane), while the main loop is spent only on planning, decisions, git mechanics, and independent verification. One unit = one branch = one worktree. Converged = min(score) > 8.5 AND zero unioned BLOCKING. Use for batches of bounded in-repo fixes where Codex credits should absorb the mechanical work and Claude tokens are reserved for judgement. Invoke as /claudex-code <goal>."
---

# /claudex-code — lane-parallel implementation with Codex as the implementer

Sibling of [`/claudex`](../SKILL.md). Where `/claudex` has **Claude** implement and Codex
review, `claudex-code` inverts it: **Codex implements and reviews, one background process per
lane**, and Claude is spent only where Claude is actually worth the money — planning,
decisions, git mechanics, and independent verification.

Use it when the work is a batch of bounded in-repo fixes: the mechanical per-lane work is what
stalls, and it is exactly the part that does not need the expensive model.

> **Platform.** Commands are POSIX (bash/zsh). The methodology was originally derived on
> Windows/PowerShell 5.1; the launcher traps specific to that platform are preserved in
> [§9](#9-appendix--windowspowershell-51-traps) because they document *why* several rules
> exist. Rules that are genuinely OS-bound are labelled.

---

## Roles — who does what, and why

| Role | Who | Why them |
|---|---|---|
| Plan, decompose into lanes, resolve decision gates, own **all** git mechanics | **Main loop** | Branch topology, merge safety and irreversible actions need the model accountable to the user in-conversation |
| Per-lane implementation | **Codex `gpt-5.6-sol`**, one detached process per lane | Cheap, parallel, and strong at bounded in-repo work with a written contract |
| Per-lane review | **Codex `gpt-5.6-sol`**, fresh stateless process | A reviewer that never saw the implementation reason is a better reviewer |
| Cross-file judgement where repo conventions decide the answer | **Claude subagent** | Knows `CLAUDE.md`, the ADRs, and which of two defensible designs this codebase actually uses |
| Independent verification | **Main loop, never delegated** | Cheap in Claude terms, and it is what catches the real problems |

**Model rule: call `gpt-5.6-sol`.** It is materially more capable than the smaller tiers and is
the default for both implementation and review here.

**Effort tiering — pick per task, do not default everything to one level:**

| `model_reasoning_effort` | Use for |
|---|---|
| `medium` | Mechanical, pattern-following work: register an entry in an existing map, add a fixture, refresh a contract, rename through a public surface, apply a known idiom to a second call site. |
| `max` | Anything subtle: concurrency and crash-recovery semantics, idempotency and replay logic, security or PII boundaries, schema design, a defect whose root cause is not yet known, or any fix a review seat raised as a correctness blocker. |

**Review seats: 2 seats, `gpt-5.6-sol`, `model_reasoning_effort=medium`.** At medium the seats
still produce specific, correct, `file:line` findings, so medium is the working default. When
unsure which tier an *implementation* task needs, use `max`: the cost difference is small next
to shipping a subtly wrong concurrency fix.

**Review the FIXES, not just the original implementation.** Every round of remediation goes back
through the same two seats with fresh evidence. A fix is a change like any other, and the
defects found in later rounds are typically in code written to satisfy earlier ones.

**Claude subagents are the exception, not the workhorse.** Use one when the question is "which
shape does *this* codebase use?" — is a new field a column or a JSON key, does a new table need
a retention registration, does this cross a module boundary. Do not use one to write a lane.

**Decisions belong to the main loop and are never delegated.** Not to a subagent, not to Codex,
not to a review seat. A lane that hits an unanswered gate STOPS and reports; the main loop
rules, records the ruling as a numbered decision with its reasoning, and hands it back. This is
deliberate: an implementer deciding its own contract is how a plan quietly becomes whatever was
convenient to build, and a reviewer deciding it is how a blocker gets argued away instead of
resolved. Codex may *surface* a conflict — that is often worth more than the code it writes —
but it never resolves one.

---

## The loop

```
 plan + decompose (main loop)
        │
        ├─ lane 1 ─► codex sol implement ─► codex sol review ─┐
        ├─ lane 2 ─► codex sol implement ─► codex sol review ─┤
        └─ lane N ─► codex sol implement ─► codex sol review ─┘
                                                              │
                              main-loop verification ◄────────┘
                        (hooks · suite · differential diff vs base)
                                      │
                              merge mechanics (main loop)
```

---

## 1. Lane setup (main loop)

One unit = one branch = one worktree. Lanes never share a tree.

```bash
git worktree add -b fix/<unit> "<worktrees-root>/<unit>" main
```

Then wire the lane, because a secondary worktree has none of the primary tree's local infra —
no virtualenv, no installed toolchain, no local config. Link or install a **real** interpreter
into the lane; do not assume the primary tree's environment directory is more than a husk.

```bash
ln -s "<real-env-root>" "<lane>/.venv"
```

**Credential handling.** Tests gated on an external service **fail** rather than skip when the
connection string is absent, so a lane that needs one must be given one. Prefer a form where the
secret never enters the connection string:

```bash
PGPASSWORD="$pw" TEST_DSN="postgresql://user@127.0.0.1:5432/<db>"
```

A secret that is not part of the DSN cannot be printed by a fixture `repr`, a failed assertion,
or an error path — which is the usual way a credential reaches a log file and a model provider.
If a lane needs a credentials file, copy it in and **delete it when the lane is done**.

**Secret sweeps must decode before searching.** Lane logs are frequently UTF-16; a UTF-8
`grep -F` returns a confident, wrong "0 matches". After any lane run:

```python
raw = open(p, "rb").read()
any(pw in raw.decode(e, errors="ignore") for e in ("utf-8", "utf-16", "latin-1"))
```

A false clean is worse than no check, because it ends the investigation.

---

## 2. Implementation — one detached Codex per lane

Tool-backgrounded long processes get killed with the call that spawned them. Launch **detached**
with a sentinel that records the exit code:

```bash
ART=<artifact-dir>; LANE=<lane>; LANEDIR=<worktree>
nohup sh -c "cd '$LANEDIR' && \
  codex exec --skip-git-repo-check -s workspace-write \
    -c model='gpt-5.6-sol' -c model_reasoning_effort=high \
    --output-last-message '$ART/$LANE.out' - < '$ART/$LANE.prompt' \
    > '$ART/$LANE.log' 2>&1; \
  echo \"EXITCODE=\$?\" > '$ART/$LANE.done'" >/dev/null 2>&1 &
```

**Confirm the launch took.** A sentinel-based wait cannot distinguish "running" from "never
started" — both look like an absent `.done`. Within ~30s, check that processes exist and logs
are non-empty:

```bash
pgrep -fl 'codex exec' | wc -l      # expect one per lane
ls -l "$ART"/*.log                  # expect non-zero, growing
```

`-s workspace-write` confines writes to the lane worktree. Never
`--dangerously-bypass-approvals-and-sandbox`.

### Liveness needs EVERY signal to agree

Each of these fails as a *single* signal:

| Signal | Where it lies |
|---|---|
| process exists | a stdin-blocked codex lives indefinitely at near-zero CPU |
| CPU rate | working lanes are API-bound and burn very little CPU — the working and stuck bands overlap |
| log growth | a lane running a full test suite emits no log for minutes and reads as frozen |

The last is the dangerous one: a forced reap during that window **destroys a lane mid-suite**.
So before killing anything, check for a live interpreter descendant (`python`/`node`/`dotnet`) —
a busy child is authoritative liveness and outranks the hard age cap.

Require all signals to agree. A monitor that cries wolf on every suite run costs a round-trip
each time and trains you to ignore it.

### Liveness is log growth, not process existence

A frozen Codex still appears in the process table. Poll the **delta**, per lane, and classify:

```bash
# CODING  = log grew since last sample
# IDLE    = flat but sentinel absent  → suspect; re-check next tick
# STOPPED = flat AND no process       → relaunch
ls -l "$ART"/*.log
```

Report per lane: log delta, commits on the branch, dirty file count. Two flat ticks in a row is
a stall, not patience. **Arm a recurring check (≈15 min) rather than deciding to look** — lanes
left unsampled sit dead for hours.

**Also check that the monitor still measures what its label claims.** A watchdog armed to answer
"are the lanes coding?" keeps printing CODING once the phase moves to verification — it is now
timing your own test run. A stale label is the same defect as an unattributable count.

### Stop lanes through the reaper, never by killing codex directly

The reaper walks the process tree and kills children first. Killing the `codex` process directly
leaves its **grandchildren** alive — codex parents a wrapper, which parents the interpreter doing
the work, and only a tree walk reaches that third level. An orphaned test run will hold a full
core indefinitely and is found only by a stray sweep.

### Always the project interpreter, never bare `python`

A lane invoking bare `python` resolves to the **system** interpreter, not the project
environment, and will run against the wrong version. It pegs a core, then orphans itself when
its wrapper exits, leaving the lane blocked on a child that will never return. Killing the
orphan lets the lane resume instantly with no work lost — far better than reaping and
relaunching.

Two corollaries: retrying with a different temp directory does **not** fix a wrong interpreter;
and a process burning heavy CPU beside a silent log is *spinning*, not thinking.

### Cap the population and reap zombies

`codex exec ... -` reads its prompt from **stdin**. When a detached launcher dies before writing
the pipe, or the pipe never closes, codex blocks on a read that will never EOF: it lives
indefinitely at near-zero CPU, holds tens of MB plus a child process, and **still appears in the
process table** — so a raw process count reads as healthy activity.

Existence is not liveness, and neither is CPU. **Do not use CPU-per-minute as the
discriminator**: codex waits on the API, so the burn is in the model, not on this box, and the
zombie and working-lane bands overlap. A threshold set to catch the former reaps the latter.

**The signal is log growth.** Resolve each codex pid to the log its launcher writes to, then
judge on that file's mtime. Rules for a reaper beside the launcher:

- **hard age cap** — nothing legitimately runs past ~120 min
- **stale log** — untouched > 6 min, past a 15-min grace, is stuck
- **no-CPU fallback** — only when the log cannot be resolved, at a threshold low enough to catch
  nothing but a corpse
- **concurrency cap** the launcher checks *before* spawning (cap probe → non-zero exit = refuse)

Kill the tree children-first so the parent cannot re-parent them. Default to a dry run that
prints its classification and require an explicit `--force`. Cap **read-only review seats**
higher (8) than **workspace-write implementation lanes** (6) — review seats finish in under a
minute and do not contend on disk.

The meta-rule is the one worth keeping: **a reaper is a destructive tool built on a heuristic,
so validate the heuristic against a known-good process before arming it.**

### Waiting on the sentinel

```bash
until [ -f "$ART/$LANE.done" ]; do sleep 10; done   # run in background
```

**Read the sentinel's mtime, not its existence.** A `.done` left by a previous attempt says
`EXITCODE=-1` and reads as a completed run.

### The implementer prompt must contain, every time

1. **Lane boundary.** Work only in this worktree. Read the primary tree, never write it. Never
   touch a sibling lane. Never the base branch. Never push — the main loop pushes.
2. **Binding decisions**, as a file path the lane reads (e.g. `DECISIONS.md`), stated to override
   the plan document on conflict.
3. **Project rules** — the hard rules from `CLAUDE.md`, quoted verbatim, not summarised.
4. **Any globally-ordered resource, pre-assigned** — migration ordinals, queue indices, port
   numbers. Never let a lane self-allocate one. "If you think you need another, STOP and report."
5. **Prohibitions, explicitly**: no skip flags, no `--no-verify`, no regenerating a lockfile or
   dependency graph to make it pass, never edit a checker or its config to make a finding
   disappear. *A red check reported honestly is worth far more than a green one that hides a
   violation.*
6. **Commit rules**: coherent commits on its own branch; state which decisions were applied.
7. **A reproduction test** that fails against the original defect and passes after.
8. **Stop-and-report**, not guess, whenever a decision belongs to the owner.

---

## 3. Review — a second, stateless Codex per lane

Fresh process, `-s read-only`, on `git diff main...<branch>` plus the commit list.

**Feed it the execution evidence.** A reviewer given only a diff will — correctly — block on "no
proof this was run". Attach hook exit codes, suite results with skip reasons, and the
baseline-red output (§4). Also attach an honest **"what is NOT proven"** section; a review of a
curated half-truth is worthless.

Output contract: `SCORE: X.X` on line 1, then `BLOCKING:`, then `ADVISORY:`.

**Converged = min(score) > 8.5 AND zero unioned BLOCKING.** Two seats with opposed personalities
(a pragmatist and an adversary) catch more than two identical ones.

If every seat fails to return a verdict, **stop and tell the user**. Do not substitute a Claude
judge, and do not treat an unreviewed diff as passing.

### The evidence packet — build it with one script, in one order

Reviewers block on missing information, and they are right to. A packet is complete when it
carries all five parts:

1. **Hook exit codes.**
2. **Suite result with every failure and every skip named**, skips grouped by reason, plus an
   explicit line saying whether any skip is gated on an absent external dependency (if one is,
   the result is **not** green).
3. **Baseline-red proof** — the new tests failing on unfixed code.
4. **A plan-vs-delivered matrix** — planned files versus `git diff --name-only main...<branch>`,
   with a per-item reason for anything undelivered.
5. **Standing refutations** — see below.

Generate all five from **one script in a fixed order**, because the verifier rewrites the file
while the matrix and notes append to it. Ad-hoc regeneration silently drops parts 4 and 5.

### Refute in the packet, not in the reply

When a seat raises a finding you have verified to be wrong, write the refutation **into the next
packet** with `file:line` evidence. Otherwise the same finding returns every round from every
fresh seat, because the answer only ever existed in a message the seats never saw.

And when a seat is right, say so plainly and fix it. An adversary seat that refuses your
preferred third option is frequently correct.

**Expect 4–5 rounds, and expect the later ones to be about evidence, not code.** Late rounds are
typically packet quality: unnamed skips, a missing matrix, an unexplained undelivered file.
Budget for that instead of reading it as the lane failing.

---

## 4. Verification — main loop, never delegated

This is the step that earns its cost. Three checks — but first, the four ways the verifier
itself lies to you. Each produces output that looks exactly like evidence.

| Defect | Symptom | Fix |
|---|---|---|
| Counts without names | "25 skipped", "1 failed" — unattributable | `pytest -q -rf -rs`. Without `-rf`, pytest prints NO failure lines, so you can report a count you cannot name |
| Hooks run under the wrong shell | A specific subset of hooks fails while the rest pass | Hooks that shell out need a real POSIX shell. **A partial failure set that is stable across runs is the tell** — investigate the runner, not the code |
| Destructive regeneration order | The delivery matrix and refutations vanish from the packet | The verifier REWRITES the evidence file; matrices and notes APPEND. Order is verify → matrix → notes. Running verify last silently erases both |
| Stale artefact read as success | A `.done` sentinel or log from an earlier run looks like a fresh pass | Compare mtime, not existence. An old log has a plausible size |

The pattern: **a number you cannot attribute is not evidence.** If the tool cannot say *which*
test, *which* skip, or *which* run produced a figure, fix the tool before trusting the figure.

**a0. Check EVERY configured hook, and name the ones you skipped.** Enumerate hooks from
`.pre-commit-config.yaml` — never hand-maintain a list, or a hook that is red will stay
unreported across every round while you report the green subset as "all hooks pass". For any
hook red on the base branch too, print the differential and say "pre-existing" — never drop it.
**A green subset presented without naming the subset is the same defect as an unattributable
count.**

**a. Did the hooks actually run?** Not "are they configured".

```bash
for h in $(<enumerate from .pre-commit-config.yaml>); do
  "$VENV/bin/python" -m pre_commit run "$h" --all-files >/dev/null 2>&1
  echo "$h: exit $?"
done
```

A hook whose `entry` contains a path separator can silently no-op on some platforms, because
pre-commit's executable resolution does not consult every platform's lookup rules. Hooks can be
dead this way for months while reporting green.

**b. Do the new tests fail on unfixed code?** A test asserted to prove a fix, but never run
against the old code, proves nothing.

```bash
git worktree add --detach /tmp/baseline-red main
cp <new test files> /tmp/baseline-red/<same paths>
cd /tmp/baseline-red && pytest <those files> -q      # expect RED
```

Same idea for a detector you widened: run its violation fixtures against the *previous* version
and confirm they exit 0 (blind) there and non-zero now.

**c. Differential gate — diff failure sets against the base.** When the baseline suite is red,
"all green" is unachievable and meaningless. Run the same invocation on both sides and compare:

```bash
pytest <target> -q      # on the lane, and on a clean worktree at main
```

Merge condition is **zero failures unique to the branch** — not zero failures. Report the numbers
both ways. Flaky tests show up here as failures on one side only; treat a test that flips without
a causal code path as flaky, not as fixed.

---

## 5. Merge mechanics (main loop only)

### The merge criterion

A lane merges when **all four** hold. Anything less is a report to the owner, not a merge.

1. The defect is fixed **and** proven by a test shown to fail before the fix.
2. Gates are green — hooks clean, zero failures unique to the branch (differential, §4c).
3. Reviews converged: min score > 8.5, zero unioned BLOCKING.
4. **Every undelivered planned file is listed with a per-item reason — committed to the branch,
   not reported to you.** Undelivered is acceptable; undelivered-and-unexplained is not.

On (4): a lane's disposition must be a committed artefact in a fixed location, and the reviewer's
diff must contain it. A reason given in a lane's final report is not in the branch, not in the
diff, and invisible to every fresh reviewer — a lane with many undelivered files and a committed
rationale clears review, while a lane with one undelivered file and a rationale only in chat is
blocked, correctly. Make the lane re-verify the claim at HEAD and cite `file:line` rather than
restating its earlier prose, and never transcribe the reason into the packet yourself: the lane's
attested statement in the repo is evidence, your paraphrase in a scratch file is not, and it will
not be there when someone reads `git log` in six months.

A lane that stops at an owner-gated approval has *succeeded*, provided the capability it gates
stays disabled and the gate is named. A lane refusing to wire something destructive on unproven
evidence is the behaviour the contract asks for.

Put each lane's undelivered-item reasons **in its merge commit**, so the reason survives where
someone reading `git log` will find it.

- **Never stash to clear the way.** A stash restore that fails on a locked file destroys WIP.
- If the primary tree has staged changes, `git merge` refuses. Build the merge in a throwaway
  worktree at `main`, then push from there — the user's tree is never touched:
  ```bash
  git worktree add -b tmp/merge-x /tmp/merge-x main
  cd /tmp/merge-x && git merge --no-ff <branch> -F <msg-file>
  git diff --stat <branch> HEAD          # MUST be empty: the merge added nothing unreviewed
  git push origin tmp/merge-x:main
  ```
- Per-unit commits stay independent so a revert can be surgical; a thin merge commit on top
  carries the evidence summary.
- Confirm no overlap between the branch's paths and the user's dirty paths before merging.
- After merging frontend changes: rebuild the bundle and copy it to the served directory **then**
  relaunch — static assets often only mount if they exist at import time — and probe the health
  endpoint.

---

## 6. The integration gate — per-lane green is not evidence

Lanes can each pass many review rounds with a fully green suite and still produce a failure per
lane the moment they are merged. Every lane's diff is correct in isolation. No amount of per-lane
review reaches this; only merging and running does.

So the last gate before any push is: merge all branches into a scratch worktree and run
everything — suite, hooks, frontend build, frontend tests — **differentially against the base**.
Absolute thresholds are useless when the baseline is already red; a gate nobody can pass is a
gate that gets bypassed.

**Watch specifically for merge-shadowing.** When two branches add the same thing at different
file offsets, git merges BOTH copies with no conflict, and the language silently lets the later
shadow the earlier:

| Shape | Caught by |
|---|---|
| duplicated fixture definitions | manual duplicate sweep |
| duplicated imports | a linter's redefinition rule |
| two complete parallel fixture sets | usage tracing |
| repeated `setattr`-style patches on one target | **only running the test** |

The last is invisible to a linter and to any type checker. Its symptom is a named mock that is
never awaited, while every substantive assertion in that test passes.

### Building a detector: prove it fires, then tune it to silence

Two rules, and the second is the one people skip:

1. **Prove it detects** — run it against a known-bad fixture, ideally reconstructed from real git
   history, and quote the output. A detector never seen to detect is not evidence.
2. **Tune it to zero findings on the real tree.** A checker that fires repeatedly on day one gets
   disabled by whoever inherits it. Narrow from the broad shape (which has legitimate instances)
   to the genuinely harmful one, while both proofs keep firing.

Apply the same suspicion to the detector itself. A scanner that reads plain UTF-8 and skips on
`SyntaxError` reports every BOM'd or unparseable file as CLEAN. **Unparseable input must be
reported as UNKNOWN, never skipped.**

---

## 7. What to hunt for — the three shapes this program keeps finding

Nearly every real defect is one of three, and none of them is the shape a test suite looks for.
When reviewing a lane or auditing a module, ask these first.

1. **The check that never ran.** Hooks can be configured, listed, reported green, and never
   execute. Every "we enforce X" claim needs a demonstration that X *fires*, not that X *exists*.
2. **The fix that didn't generalise.** A defect found in one place gets patched in one place, and
   the same shape survives across other modules. After any fix, grep for the *pattern*.
3. **The code nothing calls.** An implementation with passing tests, wired to no route, no menu
   entry, no caller. Tests are happy; the feature does not exist. Trace every new surface to a
   real entry point.

A fourth, narrower one worth its own line: **a boundary enforced on the list query and not on the
by-id fetch.** Masked rows echo back through `get_by_id`; a scoped list sits beside an unscoped
detail read. A suite that tests each endpoint alone never asks "can B reach A's row by id?".

---

## 8. Token economics — spend Codex credits, not Claude tokens

The premise of this skill is that Codex credits are cheap relative to Claude tokens. Route work
accordingly.

**Send to Codex** (default for anything bulk or mechanical):

- All per-lane implementation and review.
- Bulk reading and extraction: mining a spec, harvesting gates, building an inventory, "read N
  files and emit JSON". This is where Claude subagents are most wasteful — a single extraction
  agent can cost six figures of tokens for work Codex does for credits.
- Anything whose output is a structured file rather than a judgement.

**Keep in Claude, deliberately:**

- Planning, decomposition, owner-facing decisions, git mechanics.
- Verification (§4) — shell commands with small outputs; cheap in Claude terms, and it is what
  catches real problems.
- Cross-file judgement where `CLAUDE.md` or an ADR decides the answer. **Rare.** If the question
  has a documented answer in the repo, give Codex the citation instead of spawning a Claude agent
  to rediscover it.

**Main-loop discipline** — this is where Claude tokens quietly vanish:

- Have agents write results to disk as JSON; read a `grep`/summary, never the whole file.
- Never read a subagent transcript or a raw harness log into context — extract with a script.
- Batch independent tool calls into one message; don't re-read files already in context.
- Keep replies dense. Narration is billed.

---

## 9. Appendix — Windows/PowerShell 5.1 traps

Kept because they explain why several rules above exist. Every one produces the same external
symptom — **no log, no sentinel, nothing** — because the scriptblock dies at parse time, before a
single statement executes. From the main loop that is indistinguishable from a lane thinking hard.

| Trap | Why it bites | Do instead |
|---|---|---|
| `cmd - < file` | PowerShell has **no** `<` stdin redirection | `Get-Content -Raw file \| cmd -` |
| `$L` vs `$l` | Variables are **case-insensitive**; a loop `$l` silently clobbers an outer `$L`, so every path becomes `System.Collections.Hashtable\…` | Distinct, multi-letter names (`$LaneDir`, `$Spec`) |
| `("{0}" -f (if …))` | No inline `if` expression in 5.1 | Assign in a statement first |
| Reusing a log filename | A lingering launcher still holds the old log open, so the relaunch is blocked with no error | Write a **new** filename per attempt (`<lane>.fix2.log`) |
| Sentinel name drift | Waiting on `<lane>.done` while the launcher writes `<lane>.fix2.done` waits forever | Derive both from one variable |
| Non-ASCII in a `.ps1` | 5.1 reads a script as **ANSI** without a BOM, so a UTF-8 em-dash in a *comment* throws a parse error 20 lines away | Keep helper scripts 7-bit ASCII, or save with a BOM |

The detached-launch equivalent of the POSIX `nohup` form in §2 is
`Start-Process powershell.exe -ArgumentList "-NoProfile","-NonInteractive","-EncodedCommand",<base64 UTF-16>`,
with the prompt piped in via `Get-Content -Raw` and the exit code written to a `.done` sentinel.
Resolving a pid to its log means walking to the parent, pulling the base64 out of
`-EncodedCommand`, decoding it as UTF-16, and regexing the `Tee-Object -FilePath` target.

Two further platform-bound notes:

- Hooks that shell out need a real POSIX shell (Git Bash), invoked explicitly as
  `"C:\Program Files\Git\bin\bash.exe" -lc '…'`. PowerShell may resolve `bash` to an unavailable
  WSL shell, and the hooks that do not shell out will pass while the rest fail — a stable partial
  failure set is the tell.
- Run `git commit` through the same POSIX shell when hooks invoke bash.

---

## Invocation

`/claudex-code <goal>` — the main loop plans, decomposes into lanes, and runs the loop above.

Scale to the work: one lane for a single fix, N parallel lanes for a batch. **Prove the pipeline
on one lane before fanning out to a dozen.**

---

## Standing lessons this encodes

- **"The gate is green" and "the gate ran" are different claims.** Usually only one has been
  checked.
- **A detector must be shown to detect** — fixtures that pass on the old version prove nothing.
- **Verdicts go stale**: verify at current `main`, not against a plan document or a branch tip.
- **An agent's report is a claim, not evidence.** Re-run the checks yourself; only the diff proves
  "no new violations".
- **Verify your own tooling with the same suspicion.** A verifier is code too, and a buggy one
  emits confident, well-formatted, wrong evidence.
- **Disclose the intermittent, never the clean re-run.** A test that passes on retry is flaky
  evidence, and reporting only the green run is the same failure as reporting a count you cannot
  attribute.
- **A false clean ends the investigation** — which makes it worse than no check at all.
