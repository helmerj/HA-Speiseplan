#!/usr/bin/env bash
# REVIEWER probe mechanics inside a review workspace — add a probe test, run a tier, revert, clean.
#
# Why this exists at all: the probe steps themselves, not the reviews, were the wall-clock sink. A
# reviewer would drive a probe with one ad-hoc Bash block like
#     WT=/private/var/folders/.../T/tddloop-review-wt
#     rm -f "$WT"/src/test/.../ReviewProbe*.java
#     cat > "$WT"/src/test/.../ReviewProbeFixesTest.java <<'EOF' ... EOF
#     F=$WT/src/main/.../SoqlRenderer.java; python3 -c " ...in-place mutation... "
#     cd "$WT" && ./gradlew test
# Every one of those constructs (VAR= chain, heredoc, `>` redirect, `python3 -c` body, leading `cd`)
# defeats prefix-based permission matching, so the whole block stops for a prompt EVEN WHEN each piece
# is separately allowlisted. Measured over one loop's 577 probe commands: single-statement commands
# n=270, median 0.1s; compound blocks n=307, median 4.2s with outliers of 299s, 57s and 7h55m.
#
# So: file writes go through the Write/Edit TOOLS (no Bash), and everything else is ONE allowlistable
# script call. `Bash(scripts/review-probe.sh:*)` covers every command below.
#
# Usage (dim defaults to $REVIEW_DIM, set by `review-workspace.sh path <dim>`):
#   scripts/review-probe.sh dir   [<dim>]                 # print the workspace path (write files there)
#   scripts/review-probe.sh add   [<dim>] <src> <dest-rel> # copy a probe file INTO the workspace
#   scripts/review-probe.sh run   [<dim>] [affected|unit|build]
#   scripts/review-probe.sh revert[<dim>]                  # undo mutations to TRACKED files
#   scripts/review-probe.sh clean [<dim>]                  # revert + delete added probe files
#
# Mutation probe (revert a fix, prove the test catches it) — no shell mutation, no python one-liner:
#   1. scripts/review-probe.sh dir conformance      → $REVIEW_WT
#   2. Edit tool on $REVIEW_WT/<file>               (the mutation)
#   3. scripts/review-probe.sh run conformance      → PASS means the test does NOT catch it
#   4. scripts/review-probe.sh revert conformance
#
# Honesty rule (inherited from review-workspace.sh): tool/workspace absent → PENDING + exit 2, never a
# reported pass. "could not probe" and "probed clean" are different claims.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/loop.config"
CMD="${1:-}"; [ -n "$CMD" ] || { echo "usage: review-probe.sh dir|add|run|revert|clean [<dim>] ..." >&2; exit 2; }
shift

# A dim is optional and positional. Distinguish it from a tier/path by charset, so `run unit` and
# `run conformance unit` both work without the caller learning an argument order.
DIM="${REVIEW_DIM:-}"
case "${1:-}" in
  affected|unit|build|"") ;;
  *[!a-z0-9-]*) ;;
  *) DIM="$1"; shift;;
esac
# Derived EXACTLY as review-workspace.sh derives it — repo tag included, slashes squeezed. Omitting
# either made every probe look for a workspace that review-workspace.sh had never created, so `dir`,
# `add`, `run`, `revert` and `clean` all exited 2 for every reviewer. Keep the two in step; a change
# here without the same change there silently disables probing again.
# REVIEW_WT is what `review-workspace.sh path` exports, so an eval'd env wins over re-derivation.
REPO_TAG="$(basename "$ROOT" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9-' '-')"; REPO_TAG="${REPO_TAG%-}"
BASE_WT="${REVIEW_WORKTREE:-${TMPDIR:-/tmp}/tddloop-review-wt-$REPO_TAG}"
BASE_WT="$(printf '%s' "$BASE_WT" | tr -s '/')"
WT="${REVIEW_WT:-$BASE_WT${DIM:+-$DIM}}"
MANIFEST="$WT/.review-probes"            # files THIS script added — clean deletes exactly these
LABEL="${DIM:-default}"

need_wt(){ [ -d "$WT" ] || { echo "review-probe: no workspace at $WT — run: eval \"\$(scripts/review-workspace.sh path ${DIM:-})\"" >&2; exit 2; }; }

case "$CMD" in
  dir)
    need_wt; echo "$WT"
    ;;
  add)
    need_wt
    SRC="${1:?usage: review-probe.sh add [<dim>] <src> <dest-rel>}"; DEST="${2:?missing <dest-rel>}"
    case "$DEST" in /*|*..*) echo "review-probe: dest-rel must be inside the workspace: '$DEST'" >&2; exit 2;; esac
    [ -f "$SRC" ] || { echo "review-probe: source file not found: $SRC" >&2; exit 2; }
    mkdir -p "$WT/$(dirname "$DEST")" && cp "$SRC" "$WT/$DEST" \
      || { echo "review-probe: cannot copy $SRC → $WT/$DEST" >&2; exit 1; }
    grep -qxF "$DEST" "$MANIFEST" 2>/dev/null || echo "$DEST" >> "$MANIFEST"
    echo "review-probe[$LABEL]: added $DEST"
    ;;
  run)
    need_wt
    TIER="${1:-affected}"
    case "$TIER" in affected|unit|build) ;; *) echo "review-probe: bad tier '$TIER' (affected|unit|build)" >&2; exit 2;; esac
    ADAPTER="$HERE/adapters/${STACK:-gradle}.sh"
    [ -f "$ADAPTER" ] || { echo "review-probe: no adapter for STACK='${STACK:-}' at $ADAPTER — PENDING" >&2; exit 2; }
    cd "$WT" || { echo "review-probe: cannot enter $WT" >&2; exit 2; }
    LOGDIR="$WT/.review-logs"; mkdir -p "$LOGDIR"; export LOGDIR
    . "$ADAPTER"
    case "$TIER" in
      build) r="$(gate_build)";;
      unit)  r="$(gate_unit)";;
      # The mutation is uncommitted, so `changed_files HEAD` selects exactly the tests derived from it —
      # which is the probe's question. Selector SKIP falls back to the FULL suite, never to a green.
      affected) r="$(gate_unit_affected HEAD)"
                [ "$r" = SKIP ] && { echo "review-probe[$LABEL]: affected selector SKIP → running FULL unit suite" >&2; TIER=unit; r="$(gate_unit)"; };;
    esac
    echo "PROBE[$LABEL] $TIER: ${r:-PENDING}  (logs: $LOGDIR)"
    case "${r:-PENDING}" in
      PASS) exit 0;;
      FAIL) exit 1;;
      *) echo "review-probe[$LABEL]: could not probe (${r:-PENDING}) — report this, do NOT report clean" >&2; exit 2;;
    esac
    ;;
  revert)
    need_wt
    git -C "$WT" checkout -- . 2>/dev/null || { echo "review-probe: cannot revert tracked files in $WT" >&2; exit 1; }
    echo "review-probe[$LABEL]: tracked files reverted to HEAD"
    ;;
  clean)
    need_wt
    git -C "$WT" checkout -- . 2>/dev/null || true
    n=0
    if [ -f "$MANIFEST" ]; then
      while IFS= read -r p; do
        [ -n "$p" ] || continue
        rm -f "$WT/$p" && n=$((n+1))
      done < "$MANIFEST"
      rm -f "$MANIFEST"
    fi
    # Build outputs and the shared cache are deliberately KEPT: deleting them makes the next probe cold,
    # which is the cost this whole workspace exists to avoid.
    echo "review-probe[$LABEL]: reverted + removed $n added probe file(s) (build outputs kept warm)"
    ;;
  *) echo "usage: review-probe.sh dir|add|run|revert|clean [<dim>] ..." >&2; exit 2;;
esac
