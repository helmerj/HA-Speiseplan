# adapters/pytest.sh — sourced by gate.sh. Honesty rule: tool/daemon absent → PENDING (never PASS).
have(){ command -v "$1" >/dev/null 2>&1; }
docker_up(){ docker info >/dev/null 2>&1; }
# Does any of these paths declare $pat? Discovery must never answer "no" for the WRONG reason, and
# `grep -qs PAT a b` does exactly that: ugrep (a common `brew install`, and first on PATH once it is)
# exits 2 when any NAMED path is missing — even when another path matched — while BSD/GNU grep exit 0.
# Every candidate list below names paths that are normally absent (a repo has build.gradle OR
# build.gradle.kts, pyproject.toml OR setup.cfg), so under ugrep the whole family of discoveries
# silently answered "not declared": spotlessCheck dropped from the build tier, the project's own
# coverage rules never run, integration/e2e parked at SKIP/PENDING on repos that have them. No error,
# no log line — just a capability quietly missing from the gate. Search only paths that EXIST.
# Leading -E selects ERE; without it the pattern is a BRE, so `\|` alternation keeps working.
declares(){ ge=""; [ "$1" = -E ] && { ge="-E"; shift; }; pat="$1"; shift
  for f in "$@"; do [ -e "$f" ] && grep $ge -rqs "$pat" "$f" && return 0; done; return 1; }
changed_files(){ { git diff --name-only "${1:-HEAD}" 2>/dev/null||true; git diff --name-only --cached 2>/dev/null||true; git ls-files --others --exclude-standard 2>/dev/null||true; }|sort -u|grep -v -e '^$'||true; }
# Parallelism is per TIER and MEASURED, never a blanket `-n auto`. The old blanket form applied
# xdist to the unit tiers, where it is a PESSIMISATION — 2696 pure tests ran 8.8s serial, 10.3s at
# `-n 4`, 12.0s at `-n auto`; a nine-second suite cannot amortise worker startup — while leaving the
# 7-minute container-backed tier serial, which is the one that pays. Unit tiers now pass no `-n`.
xdist_args(){ :; }   # retained so an out-of-tree adapter calling it does not break; deliberately empty
# Integration tier only, opt-in via IT_PARALLEL_WORKERS in loop.config (default 1 = serial, i.e.
# unchanged for every existing repo). `--dist loadfile` keeps a module's session-scoped container
# fixtures on one worker; see the loop.config comment for why the count is a container multiplier.
it_parallel_args(){ python3 -c 'import xdist' >/dev/null 2>&1 || return 0
  n="${IT_PARALLEL_WORKERS:-1}"; case "$n" in ''|0|1) return 0;; esac; echo "-n $n --dist loadfile"; }
# pytest exits 5 for "no tests collected" — that is SKIP (nothing to narrow to), never PASS.
NO_TESTS_RC=5
# The formatter/linter belongs in the cheapest tier that claims "it builds" — CI runs it, so a tier
# that skips it can record PASS on a branch whose real build is RED. DISCOVERED, never assumed.
# LOCAL OVERRIDE (declared in scripts/.upstream-exempt). TWO defects in the stock version, both
# proven by injecting an unused import and watching the gate report PASS:
#   1. `compileall -q src` — this repo's sources live in custom_components/, so the only compile
#      check ran against a directory that does not exist. compileall prints "Can't list 'src'" and
#      still EXITS 0, so the miss was silent.
#   2. `python3 -m ruff check .` EXITS 0 while printing "Found N errors" — the ruff wheel's module
#      entry point does not propagate the status; only the `ruff` executable does. The lint branch
#      therefore could not fail, which made gate_build vacuous for any pure-Python repo.
# UPSTREAM CANDIDATE: both fixes are generic to the pytest adapter, not specific to this repo.
gate_build(){ have python3||{ echo PENDING;return;}
  bdirs=""; for d in src custom_components; do [ -d "$d" ] && bdirs="$bdirs $d"; done
  if [ -n "$bdirs" ]; then
    python3 -m compileall -q $bdirs 2>"$LOGDIR/build.log" || { echo FAIL;return;}
  else
    : >"$LOGDIR/build.log"
  fi
  if have ruff; then
    ruff check . >>"$LOGDIR/build.log" 2>&1 || { echo FAIL;return;}
    ruff format --check . >>"$LOGDIR/build.log" 2>&1 || { echo FAIL;return;}
  elif declares '\[tool.black\]\|black' pyproject.toml setup.cfg && python3 -c 'import black' >/dev/null 2>&1; then
    python3 -m black --check . >>"$LOGDIR/build.log" 2>&1 || { echo FAIL;return;}
  fi
  echo PASS; }
# --cov-fail-under in the project config is its OWN threshold gate; discover it and let pytest enforce
# it rather than reading a report the loop never asked anyone to check.
gate_unit(){ have pytest||have python3||{ echo PENDING;return;}
  python3 -m pytest -q -m "not integration and not e2e" >"$LOGDIR/unit.log" 2>&1 && echo PASS||echo FAIL; }
# Cheap tier only — a fast signal, NOT proof.
#   pytest-testmon installed → it tracks which tests touch which code: use it (accurate)
#   else changed TEST files that exist on disk → run exactly those
#   else (only src changed, no testmon) → SKIP, caller runs the full suite
# Never guess a test path from a src filename: a wrong guess collects nothing and, without the rc-5
# check below, would read as green.
#
# `--no-cov` on BOTH branches, and it is a correctness fix as much as a speed one. A project that puts
# `--cov-report=xml` in its pytest addopts has every pytest call rewrite coverage.xml — and this tier
# runs a SUBSET by construction. Left instrumented, a `fast` iteration overwrote the GATED coverage
# figure with the coverage of whichever handful of tests it selected, and anything reading the file
# before the next full gate saw a number no tier had ever claimed. The path-selected branch below
# already carried the flag; the testmon branch did not, so the defect was invisible in exactly the
# repos that had installed testmon to make this tier cheap.
gate_unit_affected(){ have python3||{ echo PENDING;return;}
  if python3 -c 'import testmon' >/dev/null 2>&1; then
    python3 -m pytest -q --no-cov --testmon -m "not integration and not e2e" >"$LOGDIR/fast.log" 2>&1; rc=$?
    [ "$rc" = 0 ] && { echo PASS;return;}
    [ "$rc" = "$NO_TESTS_RC" ] && { echo SKIP;return;}
    grep -qi 'no tests ran\|collected 0 items' "$LOGDIR/fast.log" && { echo SKIP;return;}
    echo FAIL; return
  fi
  ts=""; for f in $(changed_files "${1:-HEAD}"); do case "$f" in *test_*.py|*_test.py|test/*.py|tests/*.py) [ -f "$f" ] && ts="$ts $f";; esac; done
  [ -n "$ts" ]||{ echo SKIP;return;}
  python3 -m pytest -q --no-cov -m "not integration and not e2e" $ts >"$LOGDIR/fast.log" 2>&1; rc=$?
  [ "$rc" = 0 ] && { echo PASS;return;}
  [ "$rc" = "$NO_TESTS_RC" ] && { echo SKIP;return;}
  grep -qi 'no tests ran\|collected 0 items' "$LOGDIR/fast.log" && { echo SKIP;return;}
  echo FAIL; }
# Testcontainers reuse (testcontainers-python): needs with_reuse + the host property; inert otherwise, never in CI.
#
# Both coverage flags are load-bearing wherever the project puts `--cov-report` in its pytest addopts,
# which is the common case and the one the stock adapter got wrong:
#   --no-cov     on the collect-only PROBE, or the probe rewrites coverage.xml with a zero-test run and
#                the gate two lines below reads the coverage of nothing.
#   --cov-append on the real run, or integration coverage REPLACES the unit run's data instead of
#                adding to it, and the gated percentage is integration-only. Coverage is a FLOORED
#                number, so losing this reports a wrong figure rather than failing — the direction that
#                hides. Inert where coverage is not enabled at all.
gate_integration(){ have python3||{ echo PENDING;return;}; python3 -m pytest -q -m integration --collect-only --no-cov >/dev/null 2>&1||{ echo SKIP;return;}; docker_up||{ echo PENDING;return;}; export TESTCONTAINERS_REUSE_ENABLE="${TESTCONTAINERS_REUSE_ENABLE:-true}"; python3 -m pytest -q $(it_parallel_args) -m integration --cov-append >"$LOGDIR/it.log" 2>&1 && echo PASS||echo FAIL; }
gate_coverage_pct(){ x=coverage.xml;[ -f "$x" ]||{ echo;return;}; grep -o 'line-rate="[0-9.]*"' "$x"|head -1|sed -E 's/[^0-9.]//g'|awk '{printf"%d",$1*100}'; }
# ── Mutation tier ────────────────────────────────────────────────────────────
# `MUTATION_FLOOR_PCT` has been in loop.config since the harness existed with NO READER ANYWHERE, and
# TDD_PLANs declare `mutation_score_pct` per milestone. On one driven loop two consecutive milestones
# recorded a gate PASS naming a tier that had no executor — the harness's own signature failure, a
# declared gate reporting green by being unmeasured. This is the executor.
#
# Coverage says a line was EXECUTED. Mutation says an assertion would have NOTICED it change, which is
# the claim a gate on a correctness core actually wants. The two diverge exactly where it matters: one
# milestone's core sat at 100% line coverage and still leaked six mutants, two of which were real
# missing assertions (a `None` compared as 0.0, a secondary sort key dropped).
#
# Scope is $MUTATION_TARGETS (loop.config) — a DECLARED list, because a scope buried in a command line
# is a scope nobody reviews: "mutation 94%" means nothing until you can see which statements it is 94%
# of. mutmut reads the same list from pyproject's `[tool.mutmut] only_mutate` and has no CLI
# equivalent, so the list exists twice and the two are CROSS-CHECKED below rather than assumed equal.
#
# HONESTY: mutmut is normally an optional dependency group, so the common case is that it is absent.
# Absent tool → PENDING, never PASS and never FAIL: "not measured" and "measured clean" are different
# claims, and PENDING is the only verdict in this harness's vocabulary that says the first one. Every
# could-not-measure branch below is PENDING for the same reason. FAIL is reserved for a score that was
# genuinely taken and came in under the floor.
mutation_only_mutate(){ [ -f pyproject.toml ]||return 0
  awk '/^[[:space:]]*only_mutate[[:space:]]*=/{f=1} f{print} f&&/\]/{exit}' pyproject.toml \
    |grep -oE '"[^"]+"'|tr -d '"'|sort; }
mutation_targets_declared(){ printf '%s\n' ${MUTATION_TARGETS:-}|grep -v '^$'|sort; }
# The score mutmut measured, or empty. Read from the exported stats rather than from the run's exit
# code: `mutmut run` exits 0 WITH survivors, so treating rc as the verdict reports PASS for a suite
# that killed nothing.
#
# STRICT by construction — the numerator is `killed` alone. A timeout is usually counted as a kill and
# a `suspicious` result is ambiguous; counting either as killed can only push the score UP, and a
# mutation gate that rounds in its own favour is not a gate. `skipped` leaves the denominator, because
# those mutants were deliberately not run.
#
# Read PER KEY, not by field position. The first version split on `[:,]` and took field 2 of any line
# mentioning a key — correct for pretty-printed JSON and silently wrong for the compact single-line
# form, where every key matches the same line and `killed`, `survived` and `total` all read the FIRST
# number in the file. Caught by driving it over a one-line fixture in harness-selfcheck.sh.
gate_mutation_pct(){ f="$LOGDIR/mutation-stats.json"; [ -f "$f" ]||{ echo;return;}
  jnum(){ sed -nE 's/.*"'"$1"'"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$f" | head -1; }
  k="$(jnum killed)"; s="$(jnum survived)"; t="$(jnum total)"; sk="$(jnum skipped)"
  k="${k:-0}"; s="${s:-0}"; t="${t:-0}"; sk="${sk:-0}"
  d=$(( t - sk )); [ "$d" -gt 0 ]||{ echo; return; }
  # A run whose BASELINE died generates every mutant and tests none, so killed+survived is 0 while
  # total is not. 0*100/116 is 0, and a 0 meaning "measured over nothing" is indistinguishable from a
  # 0 meaning "every mutant lived" — one loop quoted the first into three documents as if it were the
  # second. Emit nothing, so the caller reports PENDING.
  [ $(( k + s )) -gt 0 ]||{ echo; return; }
  echo $(( k * 100 / d )); }
gate_mutation(){ floor="${1:-${MUTATION_FLOOR_PCT:-0}}"
  : >"$LOGDIR/mutation.log"; rm -f "$LOGDIR/mutation-stats.json"
  have python3||{ echo PENDING;return;}
  # Nothing declared to mutate is a legitimate state for a milestone whose work is all wiring — SKIP,
  # not PENDING: there is no measurement owed.
  [ -n "${MUTATION_TARGETS:-}" ]||{ echo "no MUTATION_TARGETS declared in loop.config" >>"$LOGDIR/mutation.log"; echo SKIP;return;}
  python3 -c 'import mutmut' >/dev/null 2>&1||{
    echo "mutmut is not installed — add it to the project's optional mutation dependency group" >>"$LOGDIR/mutation.log"; echo PENDING;return;}
  # A target that no longer exists means the declared scope has drifted off the code. Measuring the
  # survivors of a two-file scope and reporting it as the three-file one is the false green this tier
  # exists to prevent.
  for t in $(mutation_targets_declared); do [ -f "$t" ]||{
    echo "declared mutation target is missing from the tree: $t" >>"$LOGDIR/mutation.log"; echo PENDING;return;}; done
  if [ "$(mutation_only_mutate)" != "$(mutation_targets_declared)" ]; then
    { echo "MUTATION_TARGETS (loop.config) and [tool.mutmut] only_mutate (pyproject.toml) disagree."
      echo "loop.config:"; mutation_targets_declared; echo "pyproject.toml:"; mutation_only_mutate
    } >>"$LOGDIR/mutation.log"; echo PENDING; return
  fi
  # Cold every time. mutmut caches results under `mutants/` keyed on a config fingerprint, and a cache
  # that outlived a scope change would export stats for mutants of files no longer in scope. A cold run
  # of a properly small scope is seconds, so incrementality buys nothing worth that risk.
  rm -rf mutants
  python3 -m mutmut run >>"$LOGDIR/mutation.log" 2>&1
  python3 -m mutmut export-cicd-stats >>"$LOGDIR/mutation.log" 2>&1
  [ -f mutants/mutmut-cicd-stats.json ]||{
    echo "mutmut produced no stats — the run did not complete (a RED unit suite stops it before any mutant is tested)" >>"$LOGDIR/mutation.log"
    echo PENDING; return;}
  cp mutants/mutmut-cicd-stats.json "$LOGDIR/mutation-stats.json"
  pct="$(gate_mutation_pct)"
  [ -n "$pct" ]||{ echo "no mutation score was measured: mutmut either generated no mutants for the declared scope, or generated them and tested NONE — the latter means the baseline suite was RED inside the sandbox, so read the failure above rather than the number" >>"$LOGDIR/mutation.log"; echo PENDING;return;}
  # The surviving mutants are the deliverable, not the percentage. Append them to the log so a FAIL
  # names what to write a test for instead of a number to chase.
  { echo; echo "── surviving mutants ──"; python3 -m mutmut results 2>&1; } >>"$LOGDIR/mutation.log"
  [ "$pct" -ge "$floor" ] && echo PASS||echo FAIL; }
# Count the tagged tests BEFORE running: a tag with no tests behind it exits 0 having executed nothing,
# which is not acceptance. Zero behind the tag → PENDING (never PASS, never FAIL — it isn't written yet).
# LOCAL OVERRIDE (declared in scripts/.upstream-exempt) — upstream's gate_e2e assumes a Playwright
# e2e/ workspace. This repo is a Home Assistant custom component: there is no deployable HTTP artifact
# to drive a browser against, so "black box" means "through HA's public surface" and the e2e specs are
# pytest tests marked `@pytest.mark.e2e` + `@pytest.mark.m<n>`. Without this, gate_e2e returns PENDING
# forever and no milestone can ever go green. Upstream candidate: the pytest adapter should support a
# pytest-marker e2e tier when no playwright.config.ts exists.
# The zero-behind-the-tag → PENDING contract is preserved verbatim: a tag with no tests is not acceptance.
gate_e2e(){ have python3||{ echo PENDING;return;}
  out="$(python3 -m pytest -q --no-cov --collect-only -m "e2e and $1" 2>/dev/null || true)"
  n="$(printf '%s\n' "$out"|sed -n 's/^\([0-9][0-9]*\) tests* collected.*/\1/p'|head -1)"
  [ -n "$n" ]||n="$(printf '%s\n' "$out"|grep -cE '::'||true)"
  [ "${n:-0}" -gt 0 ]||{ echo PENDING;return;}
  python3 -m pytest -q --no-cov -m "e2e and $1" >"$LOGDIR/e2e.log" 2>&1&&echo PASS||echo FAIL; }
# Echoes "<statements> <prose>" — R8 reads the first, R12 the second. Python is split by AST; every
# other language scores raw diff lines as statements and 0 prose, so R12 cannot trip there.
# OPTIONAL BY CONTRACT: loop-iteration.sh calls this only if defined, and an adapter without it keeps
# the raw shortstat count. Falls back to "<raw> 0" on any malformed output — a breaker that silently
# stops counting is worse than one that counts the wrong thing.
# $1 is the raw fallback, $2 the base to measure FROM (defaults to HEAD, i.e. the dirty tree only —
# see loop-iteration.sh's `churn_base` for why that default read zero for twenty-odd iterations).
# `cl_raw` is captured BEFORE `set --`, which overwrites $1: reading "${1:-0}" after it fell back to
# the first field of the MALFORMED output instead of the raw diff, so a helper printing "1 2 3" over a
# 777-line diff handed R8 a budget of 1. Every fallback arm echoes both fields, including this one.
churn_loc(){ h="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/churn_loc.py"; cl_raw="${1:-0}"
  { have python3 && [ -f "$h" ]; }||{ echo "$cl_raw 0"; return; }
  v="$(python3 "$h" "${2:-HEAD}" "${SPEC_DIR:-}" 2>/dev/null)"
  case "$v" in *[!0-9\ ]*|'') echo "$cl_raw 0"; return;; esac
  set -- $v; [ $# = 2 ] && echo "$v" || echo "$cl_raw 0"; }
