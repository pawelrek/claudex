# /claudex blessed shared shell library — REGENERATED from SKILL.md Step 0g heredoc.
# Edit the heredoc in SKILL.md first, then re-extract (see SKILL.md notes: "lib.sh ships as a blessed file").
# /claudex shared shell library

# Run a command under a wall-clock timeout. Prefer `timeout`/`gtimeout`; on a
# stock macOS that has neither, fall back to a python3 wrapper (python3 is
# already a hard dependency — Step 0f-bis uses it) so a stalled `codex exec`
# can't hang preflight forever. Only if BOTH are missing do we run unwrapped.
# Portable across bash and zsh — does NOT rely on parameter-expansion word
# splitting (on in bash, off by default in zsh).
with_timeout() {
  local secs="$1"; shift
  if [ -n "${TIMEOUT_BIN:-}" ]; then
    "$TIMEOUT_BIN" "$secs" "$@"
  elif command -v python3 >/dev/null 2>&1; then
    # python3 -c (NOT a stdin heredoc) so the wrapped command keeps the
    # caller's REAL stdin — the Step 0h smoke probe pipes the prompt via
    # `... - < probe.in`, and a heredoc-on-stdin wrapper would feed codex an
    # empty prompt and brick preflight on stock macOS. The timeout seconds go
    # through the environment to avoid any argv-quoting games.
    CLAUDEX_TO_SECS="$secs" python3 -c 'import os,subprocess,sys
secs=float(os.environ["CLAUDEX_TO_SECS"]); cmd=sys.argv[1:]
try: sys.exit(subprocess.run(cmd, timeout=secs).returncode)
except subprocess.TimeoutExpired: sys.stderr.write("[with_timeout] python3 fallback fired after %ss\n"%secs); sys.exit(124)
except FileNotFoundError: sys.stderr.write("[with_timeout] command not found: %s\n"%(cmd[0] if cmd else "")); sys.exit(127)
except KeyboardInterrupt: sys.exit(130)' "$@"
  else
    "$@"
  fi
}

# Run a Codex `codex exec` invocation with a wall-clock backstop AND a JSONL
# liveness watcher. The wall-clock cap is the outer limit; the liveness
# watcher fires earlier if Codex stops emitting events for `quiet_sec`
# seconds (default 90s). Distinguishes "deep reasoning, still progressing"
# from "stuck in a loop / search rabbit-hole / lost".
#
# Model: read from $RUN_DIR/codex-model (resolved at Step 0f-bis — newest
# model the CLI offers). $RUN_DIR is threaded into every snippet's env.
#
# Usage:
#   run_codex_with_liveness <wall_clock_secs> <quiet_secs> <jsonl_path> <last_msg_path> <prompt_path> <reasoning_effort>
# Returns the codex exec exit code (0 on success, 124 on either timer fire).
run_codex_with_liveness() {
  local wall_secs="$1" quiet_secs="$2" jsonl="$3" last_msg="$4" prompt="$5" effort="$6"
  local model
  model=$(cat "$RUN_DIR/codex-model" 2>/dev/null)
  [ -z "$model" ] && model="gpt-5.5"

  codex exec \
    --skip-git-repo-check \
    -s read-only \
    -c model="$model" \
    -c model_reasoning_effort="$effort" \
    --json \
    --output-last-message "$last_msg" \
    - \
    < "$prompt" \
    > "$jsonl" 2>&1 &
  local codex_pid=$!

  # Liveness loop: every 10s, check JSONL size. If unchanged for quiet_secs,
  # signal Codex to exit. wall_secs is the outer ceiling.
  local last_size=0 last_change deadline now current_size
  last_change=$(date +%s)
  deadline=$((last_change + wall_secs))

  while kill -0 "$codex_pid" 2>/dev/null; do
    sleep 10
    now=$(date +%s)
    current_size=$(stat -c%s "$jsonl" 2>/dev/null || stat -f%z "$jsonl" 2>/dev/null || echo 0)
    if [ "$current_size" -ne "$last_size" ]; then
      last_size="$current_size"
      last_change="$now"
    fi

    if [ $((now - last_change)) -ge "$quiet_secs" ]; then
      echo "[liveness] no Codex event for ${quiet_secs}s — killing (was at ${current_size} bytes)" >&2
      kill -TERM "$codex_pid" 2>/dev/null
      sleep 2
      kill -KILL "$codex_pid" 2>/dev/null
      wait "$codex_pid" 2>/dev/null
      return 124
    fi

    if [ "$now" -ge "$deadline" ]; then
      echo "[liveness] wall-clock backstop ${wall_secs}s — killing" >&2
      kill -TERM "$codex_pid" 2>/dev/null
      sleep 2
      kill -KILL "$codex_pid" 2>/dev/null
      wait "$codex_pid" 2>/dev/null
      return 124
    fi
  done

  wait "$codex_pid"
  return $?
}

# Auto-retry a Codex call with reduced scope on failure. ~80% of session_error
# exits are recoverable by lowering reasoning_effort one notch and halving the
# wall-clock. Preserves the original attempt's artifacts at *.original.
codex_with_one_retry() {
  local wall_secs="$1" quiet_secs="$2" jsonl="$3" last_msg="$4" prompt="$5" effort="$6"

  run_codex_with_liveness "$wall_secs" "$quiet_secs" "$jsonl" "$last_msg" "$prompt" "$effort"
  local rc=$?
  if [ $rc -eq 0 ] && [ -s "$last_msg" ]; then
    return 0
  fi
  if [ $rc -eq 0 ] && [ ! -s "$last_msg" ]; then
    echo "[auto-retry] codex exited 0 but produced no last-message (empty model response) — retrying" >&2
  fi

  local next_effort
  case "$effort" in
    xhigh)  next_effort=high   ;;
    high)   next_effort=medium ;;
    medium) next_effort=low    ;;
    low)    next_effort=low    ;;
    *)      next_effort=high   ;;
  esac
  local next_wall=$((wall_secs / 2))
  if [ "$next_wall" -lt 120 ]; then next_wall=120; fi

  echo "[auto-retry] original attempt failed (rc=$rc, empty=$([ -s "$last_msg" ] && echo no || echo yes)); retrying with reasoning_effort=$next_effort, wall=${next_wall}s" >&2

  [ -s "$jsonl" ]    && mv "$jsonl"    "${jsonl}.original"
  [ -s "$last_msg" ] && mv "$last_msg" "${last_msg}.original"

  run_codex_with_liveness "$next_wall" "$quiet_secs" "$jsonl" "$last_msg" "$prompt" "$next_effort"
  local retry_rc=$?
  if [ $retry_rc -eq 0 ] && [ -s "$last_msg" ]; then
    echo "[auto-retry] recovered (effort=$next_effort)" >&2
    return 0
  fi
  return "$retry_rc"
}

# ---- Severity-section parsers -------------------------------------------
# Reviews carry up to four severity headings: BLOCKING: MAJOR: MINOR: POLISHING:
# A finding is a list item at COLUMN 0 — numbered (1.) canonical, or -, *, +
# bulleted. A section ends at the next severity heading (col 0) or an EXACT
# `---` divider line. The parser is hardened against three real corruptions
# that previously mis-gated convergence:
#   - fenced blocks: any ``` ... ``` region is skipped wholesale, so a quoted
#     diff/code block can't be miscounted (reviewers + the juror are instructed
#     to fence all quoted code/diffs);
#   - indented lines (sub-bullets, wrapped text) are NOT items — col-0 only,
#     so one finding with sub-points counts as one, not three;
#   - the divider must be a bare `---` line, so a unified-diff `--- a/x` header
#     no longer closes a section early and hides the findings below it;
#   - CR is stripped, so CRLF review files parse identically to LF.
# Fence toggle is TYPE-AWARE: a ``` block stays open across a ~~~ line and vice
# versa (only the matching marker type closes it). Implemented identically in
# every parser below + fences_balanced, so a quoted diff containing the other
# fence char can't desync the skip state.
# HEADINGS tolerate markdown decoration: matching runs on a copy stripped of
# leading #/>/*/_/`/space and trailing */_/`/space, so `**BLOCKING:**`,
# `### BLOCKING:` and `> BLOCKING:` all parse (previously they counted ZERO —
# a fail-open on the juror file). ITEMS still count on the RAW line (column-0
# discipline) and accept `1.` or `1)` numbering.
count_section_items() {
  local file="$1" heading="$2"
  awk -v HEAD="$heading" '
    BEGIN { H = "^" HEAD ":" }
    { sub(/\r$/, "") }
    /^```/ { if (!fence) { fence=1; ft="b" } else if (ft=="b") { fence=0 } next }
    /^~~~/ { if (!fence) { fence=1; ft="t" } else if (ft=="t") { fence=0 } next }
    fence                                         { next }
    /^---[[:space:]]*$/                           { in_s=0; past_div=1; next }
    past_div                                      { next }
    { h = $0; gsub(/^[[:space:]#>*_`]+/, "", h); gsub(/[*_`[:space:]]+$/, "", h) }
    h ~ H                                         { in_s=1; next }
    h ~ /^(BLOCKING|MAJOR|MINOR|POLISHING):/      { in_s=0 }
    in_s && /^([0-9]+[.)]|[-*+])[[:space:]]/      { n++ }
    END { print n+0 }
  ' "$file"
}

# Are code fences balanced, scoped to the region BEFORE the bare `---` divider?
# An UNBALANCED fence in the gated region of the JUROR file is dangerous: an
# unclosed ``` under BLOCKING: swallows the findings below it and
# count_section_items returns 0 → false convergence. We stop at `---` so an
# unbalanced fence in the ADJUDICATION appendix (quoted dismissed snippets,
# below the divider where counting already stopped) doesn't force a needless
# extra round. Steps 2e/4e refuse to converge when this returns false.
fences_balanced() {
  awk '
    /^```/ { if (!fence) { fence=1; ft="b" } else if (ft=="b") { fence=0 } next }
    /^~~~/ { if (!fence) { fence=1; ft="t" } else if (ft=="t") { fence=0 } next }
    !fence && /^---[[:space:]]*$/ { exit 0 }
    END { exit fence }
  ' "$1"
}

# Fallback for a reviewer who writes prose under BLOCKING: instead of a list.
# Same hardening (type-aware fence-skip, exact divider + seal, CR-strip); counts
# non-blank, non-heading content lines. NOTE: only ever applied to RAW REVIEWER
# files, never to the juror file — the binding gate (Steps 2e/4e) reads the
# juror file's strict list-item count, and the juror is required to write
# canonical numbered findings and to OMIT empty sections (so "heading present,
# zero items" is unambiguously zero on the file that gates convergence).
_count_body_under_blocking() {
  awk '
    { sub(/\r$/, "") }
    /^```/ { if (!fence) { fence=1; ft="b" } else if (ft=="b") { fence=0 } next }
    /^~~~/ { if (!fence) { fence=1; ft="t" } else if (ft=="t") { fence=0 } next }
    fence                                         { next }
    /^---[[:space:]]*$/                           { in_b=0; past_div=1; next }
    past_div                                      { next }
    { h = $0; gsub(/^[[:space:]#>*_`]+/, "", h); gsub(/[*_`[:space:]]+$/, "", h) }
    h ~ /^BLOCKING:/                              { in_b=1; next }
    h ~ /^(MAJOR|MINOR|POLISHING):/               { in_b=0 }
    in_b && /[^[:space:]]/                        { n++ }
    END { print n+0 }
  ' "$1"
}

# Robust BLOCKING counter for REVIEWER files: strict list-item count first,
# fall back to non-empty body lines if a BLOCKING heading is present but no
# list items parsed. Over-counting here is non-fatal — reviewer rows are
# informational and only nudge the juror's median; the binding gate uses
# count_section_items on the juror file directly.
blocking_count_robust() {
  local file="$1" items has_heading body
  items=$(count_section_items "$file" "BLOCKING")
  if grep -qE '^[[:space:]#>*_`]*BLOCKING:' "$file" 2>/dev/null; then
    has_heading=1
  else
    has_heading=0
  fi
  if [ "$has_heading" -gt 0 ] && [ "$items" -eq 0 ]; then
    body=$(_count_body_under_blocking "$file")
    if [ "$body" -gt 0 ]; then
      echo "WARNING: BLOCKING heading present but no list-style items parsed. Treating non-empty body lines as $body BLOCKING item(s)." >&2
      echo "$body"
      return
    fi
  fi
  echo "$items"
}

major_count_robust()     { count_section_items "$1" "MAJOR"; }
minor_count_robust()     { count_section_items "$1" "MINOR"; }
polishing_count_robust() { count_section_items "$1" "POLISHING"; }

# Parse the SCORE value. Fence-aware (skips ``` / ~~~ blocks, so a quoted
# `+SCORE: 2.0` decoy above the real line can't win). Strips surrounding
# markdown (>, *, `, _, spaces) BEFORE matching, so `> **SCORE:** 9.1` works,
# while prose like "the score: …" (starts with a letter, not "score:") does
# NOT match. Emits ONLY a bare decimal, or nothing — never a raw line (which
# previously fed `SCORE: N/A` into an awk comparison and crashed it).
parse_score() {
  awk '
    { sub(/\r$/, "") }
    /^```/ { if (!fence) { fence=1; ft="b" } else if (ft=="b") { fence=0 } next }
    /^~~~/ { if (!fence) { fence=1; ft="t" } else if (ft=="t") { fence=0 } next }
    fence { next }
    /^---[[:space:]]*$/ { past_div=1; next }
    past_div { next }
    {
      line = $0
      gsub(/[#*_`>[:space:]]/, "", line)
      if (tolower(substr(line, 1, 6)) == "score:") {
        rest = substr(line, 7)
        if (match(rest, /[0-9]+(\.[0-9]+)?/)) {
          tok = substr(rest, RSTART, RLENGTH)
          # Range-guard: a score must be in (0, 10]. An out-of-range value
          # (e.g. a malformed `SCORE: 99.0`) would otherwise pass `> 8.5` and
          # falsely converge — emit nothing so the gate treats it as no-score.
          if (tok + 0 > 0 && tok + 0 <= 10) { print tok; exit }
        }
      }
    }
  ' "$1"
}

# Is there a SUBSTANTIATED CLEAN — the bare token CLEAN on its own line (modulo
# surrounding markup) AND ≥1 other non-blank content line (the what-was-checked
# list, on either side)? Prints 1/0. Used by panel_row to keep an unsubstantiated
# `CLEAN` (or a hollow "Cleanly done." rubber-stamp) from counting as a review.
clean_substantiated() {
  awk '
    { sub(/\r$/, "") }
    /^```/ { if (!fence) { fence=1; ft="b" } else if (ft=="b") { fence=0 } next }
    /^~~~/ { if (!fence) { fence=1; ft="t" } else if (ft=="t") { fence=0 } next }
    fence                                              { next }
    { s=$0; gsub(/[#*_`>[:space:]]/, "", s) }
    toupper(s) == "CLEAN"                              { has_clean=1; next }
    s ~ /^(BLOCKING|MAJOR|MINOR|POLISHING):/           { next }
    /^---[[:space:]]*$/                                { next }
    tolower(substr(s,1,6)) == "score:"                 { next }
    /[^[:space:]]/                                     { content++ }
    END { print (has_clean && content >= 1) ? 1 : 0 }
  ' "$1"
}

# Append one row to a panel TSV and echo the human-readable summary.
# Usage: panel_row <tsv_path> <iteration> <reviewer_label> <review_file> <score_target>
# Writes: iteration  reviewer  score  blocking  major  minor  polishing  verdict
panel_row() {
  local tsv="$1" iter="$2" label="$3" file="$4" target="$5"
  local score blocking major minor polishing verdict
  if [ ! -s "$file" ]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$iter" "$label" "0.0" "0" "0" "0" "0" "EMPTY" >> "$tsv"
    echo "$label: EMPTY (no review produced)"
    return
  fi
  score=$(parse_score "$file"); [ -z "$score" ] && score=0
  blocking=$(blocking_count_robust "$file")
  major=$(major_count_robust "$file")
  minor=$(minor_count_robust "$file")
  polishing=$(polishing_count_robust "$file")
  local total_items=$((blocking + major + minor + polishing))
  # Evidence rule (protocol): a review with NO findings only counts if it
  # carries a SUBSTANTIATED CLEAN — a CLEAN token followed by ≥1 non-blank line
  # saying what was checked. A bare `CLEAN`, or a score line with nothing else,
  # is an unsubstantiated pass → recorded EMPTY so it does NOT count toward
  # quorum and cannot rubber-stamp a round.
  if [ "$total_items" -eq 0 ]; then
    if [ "$(clean_substantiated "$file")" -ne 1 ]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$iter" "$label" "${score:-0.0}" "0" "0" "0" "0" "EMPTY" >> "$tsv"
      echo "$label: EMPTY (no findings and no substantiated CLEAN — does not count toward quorum)"
      return
    fi
  fi
  if awk "BEGIN { exit !($score > $target) }" && [ "$blocking" -eq 0 ]; then
    verdict="PASS"
  else
    verdict="IMPROVE"
  fi
  # Contract violation: low score with nothing actionable (no BLOCKING, no MAJOR).
  if ! awk "BEGIN { exit !($score > $target) }" && [ "$blocking" -eq 0 ] && [ "$major" -eq 0 ]; then
    verdict="MALFORMED"
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$iter" "$label" "$score" "$blocking" "$major" "$minor" "$polishing" "$verdict" >> "$tsv"
  echo "$label: score=$score B=$blocking M=$major m=$minor p=$polishing → $verdict"
}

# Render a panel TSV as the canonical ROUND-MATRIX table (markdown): one row
# per round, reviewers as columns, scores only. Per-reviewer B/M/m/p counts
# stay in the TSV (the run's data store); the JUROR column carries the binding
# score and its accepted Open B/M counts. Cell markers: `—` = EMPTY seat,
# score suffixed `✗` = MALFORMED review.
# Usage: render_panel_table <tsv_path> <out_md_path>
render_panel_table() {
  local tsv="$1" out="$2"
  {
    echo "| Rnd | codex | VULCAN | MERIDIAN | JUROR | Open B/M | Verdict |"
    echo "|----:|------:|-------:|---------:|------:|:--------:|:-------:|"
    awk -F'\t' '
      {
        n=$1
        if (!(n in seen)) { seen[n]=1; order[++rounds]=n }
        s=$3
        if ($8=="EMPTY") s="—"; else if ($8=="MALFORMED") s=s"✗"
        if ($2 ~ /^codex/)         c[n]=s
        else if ($2 ~ /^VULCAN/)   v[n]=s
        else if ($2 ~ /^MERIDIAN/) m[n]=s
        else if ($2 ~ /^JUROR/)    { j[n]=$3; b[n]=$4; M[n]=$5; verd[n]=$8 }
      }
      END {
        for (i=1;i<=rounds;i++) {
          n=order[i]
          vd=verd[n]
          if (vd=="PASS") vd="✅ PASS"; else if (vd=="QUORUM_FAIL") vd="⚠ QUORUM"; else if (vd=="") vd="…"
          printf "| %s | %s | %s | %s | %s | %sB / %sM | %s |\n", \
            n, (c[n]==""?"—":c[n]), (v[n]==""?"—":v[n]), (m[n]==""?"—":m[n]), \
            (j[n]==""?"—":j[n]), (b[n]==""?"0":b[n]), (M[n]==""?"0":M[n]), vd
        }
      }' "$tsv"
  } > "$out"
}

# Render the run-wide findings ledger as markdown.
# ledger.tsv columns: id  sev  found_by  file  issue  status
# Usage: ledger_render <tsv_path> <out_md_path>
# NOTE: the loop variable is `stat_col`, NOT `status` — `status` is a READ-ONLY
# special parameter in zsh and assigning to it aborts the function there.
ledger_render() {
  local tsv="$1" out="$2" total
  total=$(grep -c . "$tsv" 2>/dev/null); total=${total:-0}
  {
    echo "**All findings (deduped, ${total:-0} real)**"
    echo ""
    echo "| # | Sev | Found by | File | Issue | Status |"
    echo "|---|-----|----------|------|-------|--------|"
    while IFS=$'\t' read -r id sev found_by file issue stat_col || [ -n "$id" ]; do
      [ -z "$id" ] && continue
      echo "| $id | $sev | $found_by | $file | $issue | $stat_col |"
    done < "$tsv"
  } > "$out"
}

# Return the set of pre-existing dirty paths (one per line) as captured at
# preflight in baseline-dirty-paths.txt. Path-only and UNQUOTED so it compares
# cleanly with `git diff --name-only -z` output later.
baseline_paths() {
  if [ -s "$RUN_DIR/baseline-dirty-paths.txt" ]; then
    cat "$RUN_DIR/baseline-dirty-paths.txt"
  fi
}

# Emit a block of UNTRUSTED data wrapped in per-run-nonce markers. The nonce
# (random, unguessable, unique to this run) is what makes the fence
# unforgeable: a malicious spec/diff can paste the literal marker word, but it
# cannot know the nonce, so injected "closing markers" don't match the ones the
# reviewer is told are authoritative. Usage:
#   emit_fenced <TYPE> <nonce> <file> <label>
emit_fenced() {
  local type="$1" nonce="$2" file="$3" label="$4"
  if [ -n "$label" ]; then
    printf '<<<CLAUDEX:%s:%s %s\n' "$type" "$nonce" "$label"
  else
    printf '<<<CLAUDEX:%s:%s\n' "$type" "$nonce"
  fi
  cat "$file"
  printf '\nCLAUDEX:%s:%s>>>\n' "$type" "$nonce"
}
