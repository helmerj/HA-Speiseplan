#!/usr/bin/env bash
# Role write-scope globs from loop.config. Driver enforces (check-scope.sh).
role_globs() { case "$1" in
  test-author) printf '%s\n' "$TEST_SCOPE";;
  implementer) printf '%s\n' "$MAIN_SCOPE";;
  reviewer)    printf '%s\n' "$REVIEW_SCOPE";;
  verifier)    printf '%s\n' "$REVIEW_SCOPE";;   # harness 1.8.0: re-proves findings by id; writes only review-results/
  driver)      printf '%s\n' "$DRIVER_SCOPE";;
  bootstrap)   printf '%s\n' "$BOOTSTRAP_SCOPE";;
  *) echo "UNKNOWN_ROLE:$1" >&2; return 2;; esac; }
path_in_scope() { local role="$1" path="$2" glob
  while IFS= read -r glob; do [ -z "$glob" ] && continue
    case "$path" in ${glob%/*}/*) return 0;; $glob) return 0;; esac
  done < <(role_globs "$role"); return 1; }
# Which roles COULD have written this path. check-scope only answers "is this file in the scope of the
# role I was given", so a caller that passes the wrong role gets a bare R6 trip and no way to tell a
# genuine cross-role edit from its own mis-call. Observed cost: a `commitStage` that hardcoded
# `implementer` for every step tripped R6 on a test file the test-author had written, and the trip read
# as an agent violation. Naming the owner turns that into a one-line diagnosis.
owning_roles() { local path="$1" role out=""
  for role in test-author implementer reviewer driver bootstrap; do
    path_in_scope "$role" "$path" 2>/dev/null && out="$out $role"
  done
  printf '%s' "${out# }"; }
