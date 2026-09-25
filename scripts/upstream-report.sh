#!/usr/bin/env bash
# upstream-report.sh [--since <rev>] — at a milestone close-out, name the harness changes this
# milestone made that are NOT declared local, i.e. the candidates for upstreaming to the recipe.
#
# WHY
# ---
# `harness-selfcheck.sh` detects drift in ONE direction: it catches the template regressing underneath
# a repo, and has nothing to say when the repo IMPROVES on the template. Both are drift; only the
# downgrade was instrumented. Measured cost of that asymmetry: the published recipe sat behind one
# repo by six generic mechanisms, some for months, and one of them shipped a self-check that FAILED on
# first install to every repo that took the recipe. It was found by accident, while installing into a
# scratch repo to check something unrelated.
#
# REPORTS, NEVER GATES. This prints and exits 0 — always, including when git is unavailable or the
# range does not resolve. A gate row failing on un-upstreamed changes would block a milestone on
# ANOTHER repo's review process, which is not a thing this repo's loop can be made to wait for. The
# `|| true` at its call site in open-milestone-pr.sh is belt-and-braces on top of that.
#
# Two files are excluded by construction rather than by declaration, because neither can ever be an
# upstream candidate: `scripts/loop.config` (the per-project file, which install-harness.sh never
# writes) and `scripts/.upstream-exempt` (the declaration itself — a commit that only edits the
# manifest is bookkeeping about local extensions, not a change to the harness).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"; cd "$ROOT" || exit 0
# Sourced only for BASE_BRANCH, and optional: this script must be runnable in a repo whose loop.config
# is half-written, and it must never inherit that file's `set -e` habits.
# shellcheck disable=SC1091
[ -f "$HERE/loop.config" ] && . "$HERE/loop.config" >/dev/null 2>&1
BASE="${BASE_BRANCH:-main}"

# ── version + content drift, before the commit-range report ──────────────────
# The range report answers "what did THIS milestone change"; it cannot answer "is this repo running
# an old harness", which is the question that actually costs money: a defect fixed in the plugin
# three milestones ago is invisible here, and the next project re-finds it. Measured: one repo ran a
# month behind the recipe on six generic mechanisms. So compare the installed stamp and the installed
# BYTES against the source, when the source is resolvable.
#
# Report-only, like everything else in this file: a missing source, a missing stamp and a missing
# checksum tool each print one line and change no exit code.
harness_source() {
  if [ -n "${KITCHEN_ROOT:-}" ] && [ -d "${KITCHEN_ROOT}/plugins/workflows/skills/tdd-loop-run-recipe/templates/scripts" ]; then
    echo "${KITCHEN_ROOT}/plugins/workflows/skills/tdd-loop-run-recipe/templates/scripts"; return
  fi
  ls -1d "${CLAUDE_PLUGIN_ROOT:-$HOME/.claude/plugins/cache/claudes-kitchen}"/workflows/*/skills/tdd-loop-run-recipe/templates/scripts 2>/dev/null | head -1
}
report_drift() {
  src="$(harness_source)"
  here_v="$(cat "$HERE/HARNESS_VERSION" 2>/dev/null || echo unstamped)"
  if [ -z "$src" ] || [ ! -d "$src" ]; then
    echo "── harness version: $here_v installed · source not resolvable (set KITCHEN_ROOT to compare)"
    echo; return
  fi
  src_v="$(cat "$src/HARNESS_VERSION" 2>/dev/null || echo unstamped)"
  # Only files the installer actually writes are comparable. loop.config is per-project by
  # construction, and a declared-local file is a decision already recorded, not drift.
  drifted=""; behind=""
  for f in "$HERE"/*.sh "$HERE"/adapters/*.sh "$HERE"/lib/*; do
    [ -f "$f" ] || continue
    rel="${f#"$HERE"/}"
    case "$rel" in loop.config) continue;; esac
    [ -f "$src/$rel" ] || continue
    grep -qxF "scripts/$rel" "$HERE/.upstream-exempt" 2>/dev/null && continue
    cmp -s "$f" "$src/$rel" || drifted="$drifted
      $rel"
  done
  [ "$here_v" = "$src_v" ] || behind=" (source ships $src_v)"
  if [ -z "$drifted" ]; then
    echo "── harness version: $here_v installed$behind · no content drift from the source"
  else
    echo "── harness version: $here_v installed$behind · files differing from the source:$drifted"
    echo "  A file here that is BETTER than the source is an upstream candidate; one that is merely OLDER"
    echo "  means re-running install-harness.sh. The commit report below says which of the two it is."
  fi
  echo
}
report_drift
SINCE=""; while [ $# -gt 0 ]; do case "$1" in --since) SINCE="${2:-}"; shift 2;; *) shift;; esac; done
git rev-parse --git-dir >/dev/null 2>&1 || { echo "upstream: not a git repository — no report"; exit 0; }

# ── the range, and WHY that range ────────────────────────────────────────────
# The close-out's question is "what does THIS milestone carry", so the default is the range the PR
# itself will contain: merge-base(BASE, HEAD)..HEAD.
#
# The story asked for `<previous-tag>..HEAD` and that is the FALLBACK rather than the default, on
# evidence: the harness tags a milestone AFTER its merge (open-milestone-pr.sh's closing line), so the
# newest tag is a milestone behind at the moment this runs — and in the repo this was verified
# against, the newest tag was `m7` while the milestone closing was C6, thirteen milestones later. A
# tag-first default would have reported the whole second phase as candidates every single close-out,
# which is a list nobody reads twice. Tags are still used where there is no base branch to compare to.
how=""; RANGE=""
if [ -n "$SINCE" ]; then
  git rev-parse --verify -q "$SINCE" >/dev/null 2>&1 \
    && { RANGE="$SINCE..HEAD"; how="--since $SINCE"; } \
    || { echo "upstream: --since '$SINCE' does not resolve — no report"; exit 0; }
fi
if [ -z "$RANGE" ]; then
  for ref in "$BASE" "origin/$BASE"; do
    mb="$(git merge-base "$ref" HEAD 2>/dev/null)" || continue
    [ -n "$mb" ] && { RANGE="$mb..HEAD"; how="since this branch left $ref"; break; }
  done
fi
if [ -z "$RANGE" ]; then
  tag="$(git describe --tags --abbrev=0 2>/dev/null || true)"
  [ -n "$tag" ] && { RANGE="$tag..HEAD"; how="since tag $tag (no '$BASE' branch to compare to)"; }
fi
# No base branch and no tag is the FIRST milestone of a fresh repo. Whole history is the honest answer
# there, and it is STATED — a silently empty report and "nothing to upstream" must never look alike.
[ -z "$RANGE" ] && { RANGE="HEAD"; how="whole history — no '$BASE' branch and no tag, so this is a first milestone"; }

# ── what the repo has declared local ─────────────────────────────────────────
# Same file and same two entry kinds as install-harness.sh: a PATH (this file is local) or a SYMBOL
# (this function/variable is local). Absent manifest = nothing declared, which is the normal case.
MANIFEST="$HERE/.upstream-exempt"
entries(){ [ -f "$MANIFEST" ] || return 0
  sed -e 's/#.*//' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' "$MANIFEST" | grep -v '^$' || true; }
is_path(){ case "$1" in */*|*.sh|*.py|*.md|*.json|*.config|*.template) return 0;; *) return 1;; esac; }
PATHS=""; SYMS=""
while IFS= read -r e; do
  [ -n "$e" ] || continue
  if is_path "$e"; then PATHS="$PATHS
scripts/${e#scripts/}"; else SYMS="$SYMS
$e"; fi
done <<EOF
$(entries)
EOF

# A file is COVERED when every hunk this commit changed in it touches a declared symbol. Hunk-level,
# not file-level, and that is the whole point of preferring symbols: a commit that extends a declared
# local function AND fixes something generic in the same file must still surface the generic half.
# File-level attribution would swallow it, which is the failure this report exists to prevent, wearing
# a different hat.
file_state(){ sha="$1"; f="$2"
  case "
$PATHS" in *"
$f"*) echo declared; return;; esac
  [ -n "$SYMS" ] || { echo open; return; }
  d="$(git diff -U0 "$sha^" "$sha" -- "$f" 2>/dev/null || git show --format= -U0 "$sha" -- "$f" 2>/dev/null)"
  [ -n "$d" ] || { echo open; return; }
  # Symbols reach awk through the ENVIRONMENT, not through `-v`: BSD awk rejects a newline inside a
  # `-v` assignment ("newline in string"), and this list is newline-delimited by construction. The
  # failure was not silent but it was per-file, so the report still printed — with every commit
  # looking undeclared. Exactly the noise-nobody-reads failure mode, arriving through the parser.
  printf '%s\n' "$d" | SYMS="$SYMS" awk '
    BEGIN { n = split(ENVIRON["SYMS"], S, "\n") }
    function close_hunk() { if (inh) { hunks++; if (dec) dhunks++ } }
    /^@@/ { close_hunk(); inh = 1; dec = 0; next }
    /^(\+\+\+|---)/ { next }
    /^[+-]/ { for (i = 1; i <= n; i++) if (S[i] != "" && index($0, S[i]) > 0) { dec = 1; break } }
    END { close_hunk()
          if (hunks == 0)          { print "open" }
          else if (dhunks == hunks){ print "declared" }
          else if (dhunks > 0)     { printf "partial %d %d\n", dhunks, hunks }
          else                     { print "open" } }'; }

shown=0; hidden=0; files=0; out=""
for sha in $(git log --format=%h "$RANGE" -- scripts/ 2>/dev/null); do
  lines=""; open=0; any=0
  for f in $(git show --pretty=format: --name-only "$sha" -- scripts/ 2>/dev/null | grep -v '^$' | sort -u); do
    case "$f" in scripts/loop.config|scripts/.upstream-exempt) continue;; esac
    any=1
    st="$(file_state "$sha" "$f")"
    case "$st" in
      declared) ;;
      partial*) open=$((open+1)); files=$((files+1))
                lines="$lines
      $f   (partially declared — $(printf '%s' "$st" | cut -d' ' -f2) of $(printf '%s' "$st" | cut -d' ' -f3) hunks are local)";;
      *)        open=$((open+1)); files=$((files+1)); lines="$lines
      $f";;
    esac
  done
  [ "$any" = 1 ] || continue
  if [ "$open" = 0 ]; then hidden=$((hidden+1)); continue; fi
  shown=$((shown+1))
  out="$out
  $sha  $(git log -1 --format=%s "$sha" 2>/dev/null)$lines"
done

# An EMPTY report says so in one line. Silence and "nothing to upstream" must be distinguishable, or
# the next reader cannot tell a clean milestone from a reporter that never ran.
# `${hidden:+…}` is wrong here and was wrong once: hidden is the STRING "0" when nothing was excluded,
# which is not empty, so the suffix printed "; 0 commit(s) declared local and excluded" on every clean
# report. Test the number.
excl=""; [ "$hidden" -gt 0 ] 2>/dev/null && excl="$hidden commit(s) excluded as declared local"
if [ "$shown" = 0 ]; then
  echo "── upstream candidates: none — no undeclared scripts/ change in $RANGE ($how)${excl:+; $excl}"
  exit 0
fi
echo "── upstream candidates — scripts/ changes in $RANGE ($how) ──$out"
echo
echo "  $shown commit(s) · $files file(s)${excl:+ · $excl}"
echo "  Candidates, not obligations: upstream what is generic, and declare what is not in scripts/.upstream-exempt."
echo "  This never gates — the milestone lands either way."
exit 0
