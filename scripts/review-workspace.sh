#!/usr/bin/env bash
# REVIEWER probe workspace — create/reuse a worktree with a SHARED, warm build cache.
#
# Why: reviewers were inventing their own scratch copy (`git archive HEAD` into a tmp dir) for every
# mutation probe. Each probe therefore paid a COLD cache: full compile + full suite + dependency
# resolution, ~40-70s each. Three review iterations with 4-5 probes apiece is where ~80 minutes went.
# A reused worktree plus a shared cache home makes the second and later probes incremental.
#
# Why NAMED workspaces: a round fans out N dimension reviewers CONCURRENTLY, and one shared path made
# them collide — so they hand-rolled `git worktree add ${TMPDIR}/tddloop-review-wt-<dim>` themselves
# (one observed loop: 30 ad-hoc `worktree add`, 12 `worktree remove`, 18 `git archive`, against 51
# calls to this script). A literal TMPDIR path can never be pre-allowlisted, so each hand-rolled step
# stopped for a permission prompt — one blocked 7h55m overnight. Naming the workspace HERE keeps every
# workspace operation a single allowlistable script call.
#
# Usage:
#   eval "$(scripts/review-workspace.sh path)"              # shared/default workspace
#   eval "$(scripts/review-workspace.sh path conformance)"  # per-dimension workspace
#   scripts/review-workspace.sh clean [<dim>]               # remove one worktree, KEEP the shared cache
#   scripts/review-workspace.sh clean-all                   # remove default + every per-dimension one
#
# Honesty rule: if the workspace cannot be created, this prints a diagnostic to stderr and exits
# non-zero. The reviewer then falls back to its previous behaviour and SAYS SO — a probe is never
# silently skipped, because "could not probe" and "probed clean" are different claims.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/loop.config"
CMD="${1:-path}"
# Cache home lives OUTSIDE the worktree so it survives `clean` and is shared by every probe — and by
# every dimension: a per-dimension worktree with its own cache would be cold N times over.
CACHE_ROOT="$(printf '%s' "${REVIEW_CACHE_ROOT:-${TMPDIR:-/tmp}/tddloop-review-cache}" | tr -s '/')"
# Scoped to THIS repo. TMPDIR is per-user, not per-repo, so an unscoped `tddloop-review-wt` is shared by
# every checkout on the machine: the second repo's `worktree add` failed with "path in use" (which is how
# reviewers ended up inventing their own suffixed paths), and worse, a `clean-all` in repo B would have
# removed repo A's LIVE review worktree. Scoping makes the sweep provably local to this repo.
#
# macOS TMPDIR also ends with '/' and /var is a symlink to /private/var, so the naive
# "${TMPDIR}tddloop-review-wt" is `/var/folders/…/T//tddloop-review-wt` while git reports
# `/private/var/folders/…/T/tddloop-review-wt`. Comparing those as strings silently matched NOTHING:
# clean-all said "removed 0" while the worktree it had just created stayed registered. Squeeze duplicate
# slashes here, resolve to a physical path in phys() below.
REPO_TAG="$(basename "$ROOT" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9-' '-')"; REPO_TAG="${REPO_TAG%-}"
BASE_WT="${REVIEW_WORKTREE:-${TMPDIR:-/tmp}/tddloop-review-wt-$REPO_TAG}"
BASE_WT="$(printf '%s' "$BASE_WT" | tr -s '/')"
# Dimension names come from loop.config REVIEW_DIMENSIONS and land in a filesystem path: restrict the
# charset instead of trusting the caller not to pass `../` or a space.
NAME="${2:-}"
case "$NAME" in
  "") ;;
  *[!a-z0-9-]*) echo "review-workspace: bad name '$NAME' (allowed: a-z 0-9 -)" >&2; exit 2;;
esac
WT="$BASE_WT${NAME:+-$NAME}"

# Per-stack cache environment. Keep this the ONLY stack-specific part of the script.
# The directories are created here, not just named: not every tool creates its own cache home, and a
# cache home that does not exist silently degrades every probe back to a cold run.
cache_exports(){ case "${STACK:-gradle}" in
  gradle) mkdir -p "$CACHE_ROOT/gradle"; echo "export GRADLE_USER_HOME='$CACHE_ROOT/gradle'";;
  maven)  mkdir -p "$CACHE_ROOT/m2"; echo "export MAVEN_OPTS=\"\${MAVEN_OPTS:-} -Dmaven.repo.local=$CACHE_ROOT/m2\"";;
  npm)    mkdir -p "$CACHE_ROOT/npm"; echo "export npm_config_cache='$CACHE_ROOT/npm'";;
  pytest) mkdir -p "$CACHE_ROOT/uv" "$CACHE_ROOT/pip"; echo "export UV_CACHE_DIR='$CACHE_ROOT/uv'; export PIP_CACHE_DIR='$CACHE_ROOT/pip'";;
  go)     mkdir -p "$CACHE_ROOT/go-build" "$CACHE_ROOT/go-mod"; echo "export GOCACHE='$CACHE_ROOT/go-build'; export GOMODCACHE='$CACHE_ROOT/go-mod'";;
  cargo)  mkdir -p "$CACHE_ROOT/cargo"; echo "export CARGO_HOME='$CACHE_ROOT/cargo'";;
  *)      echo "# no cache mapping for STACK='${STACK:-}' — probes run with the tool's default cache" ;;
esac; }

# Physical path (symlinks resolved) without requiring realpath — bash 3.2 / BSD. The leaf need not
# exist; its parent must.
phys(){ d="${1%/}"; b="${d##*/}"; p="${d%/*}"; [ -n "$p" ] || p=/
  ( cd "$p" 2>/dev/null && printf '%s' "$(pwd -P)/$b" ) || printf '%s' "$d"; }
BASE_PHYS="$(phys "$BASE_WT")"
# Registered worktree paths, one per line. Must be matched EXACTLY (-x): `<base>` is a prefix of
# `<base>-conformance`, so a substring match reported the default workspace as already registered as
# soon as any named sibling existed, and `path` then took the reuse branch on a directory that was
# never created. Compared as PHYSICAL paths — git prints /private/var, TMPDIR says /var.
wt_registered(){ w="$(phys "$1")"
  git -C "$ROOT" worktree list --porcelain 2>/dev/null | sed -n 's/^worktree //p' \
    | while IFS= read -r p; do [ "$(phys "$p")" = "$w" ] && echo hit; done | grep -q hit; }

remove_wt(){ # $1 = worktree path
  git -C "$ROOT" worktree remove --force "$1" 2>/dev/null || rm -rf "$1"
  git -C "$ROOT" worktree prune 2>/dev/null || true; }

case "$CMD" in
  path)
    mkdir -p "$CACHE_ROOT" || { echo "review-workspace: cannot create cache root $CACHE_ROOT" >&2; exit 1; }
    if [ -e "$WT/.git" ] || wt_registered "$WT"; then
      # Reuse: point it at the commit under review, keep the build outputs already there.
      git -C "$WT" checkout -q --detach HEAD 2>/dev/null || true
      git -C "$WT" fetch -q "$ROOT" HEAD 2>/dev/null || true
      git -C "$WT" checkout -q --detach FETCH_HEAD 2>/dev/null \
        || { echo "review-workspace: worktree at $WT exists but cannot be pointed at HEAD" >&2; exit 1; }
      # `checkout --detach` preserves non-conflicting local modifications BY DESIGN, so a mutation from
      # an earlier probe — one that crashed, or whose `review-probe.sh revert` was never run — survived
      # into the next round and was reported as ready. The reviewer then probed deliberately broken
      # source and attributed the failure to the implementer. Reset tracked files; leave UNTRACKED build
      # output alone, which is the whole point of reusing the workspace.
      git -C "$WT" reset -q --hard FETCH_HEAD 2>/dev/null \
        || { echo "review-workspace: cannot reset the reused worktree at $WT to HEAD" >&2; exit 1; }
    else
      git -C "$ROOT" worktree add -q --detach "$WT" HEAD 2>/dev/null \
        || { echo "review-workspace: cannot create worktree at $WT (not a git repo, or path in use)" >&2; exit 1; }
    fi
    echo "export REVIEW_WT='$WT'"
    [ -n "$NAME" ] && echo "export REVIEW_DIM='$NAME'"
    cache_exports
    ;;
  clean)
    remove_wt "$WT"
    echo "review-workspace: removed $WT (shared cache kept at $CACHE_ROOT)"
    ;;
  clean-all)
    # Sweep the default path AND every `<base>-<dim>` sibling: a round that died mid-fan-out otherwise
    # leaves worktrees behind for the next round to trip over. Iterating the FILESYSTEM rather than
    # `git worktree list` is deliberate — a directory whose registration was already pruned (or that was
    # created against a repo since deleted) is exactly the orphan that makes the next `worktree add`
    # fail with "path in use", and a registration-only sweep left it forever.
    removed=0
    for p in "$BASE_WT" "$BASE_WT"-*; do
      [ -d "$p" ] || continue
      remove_wt "$p"; removed=$((removed+1)); echo "review-workspace: removed $p"
    done
    echo "review-workspace: clean-all removed $removed worktree(s) (shared cache kept at $CACHE_ROOT)"
    ;;
  *) echo "usage: review-workspace.sh [path|clean] [<dim>] | clean-all" >&2; exit 2;;
esac
