#!/usr/bin/env bash
# harness_sha.sh — ONE number for "which harness is this". Two worktrees of one repo ran drivers
# 248 lines apart that both said 1.6.0 (TT-4348 M2_RETRO §4.1); a version string is a claim, a hash
# of the scripts is a measurement. install-harness.sh writes scripts/HARNESS_SHA from the copy it just
# made; loop-driver.sh recomputes it before spending money and refuses on a mismatch, unless the
# repo declares local edits in scripts/.upstream-exempt or sets HARNESS_SHA_CHECK=0.
#
# Over the harness's OWN files only — every *.sh at scripts/ and under lib/, plus lib/*.py — never
# loop.config (the operator's), never adapters/ (tuned per stack, and fixtures install stubs there),
# never README.md. Sorted, so the order of `ls` on two filesystems cannot make two equal harnesses
# hash differently. cksum: POSIX, on BSD and GNU alike.
#
# EVERY scripts/*.sh, which means a project's own scripts must not sit beside the harness: a
# `scripts/sf-smoke.sh` added by a milestone moves the hash and `run` refuses on it (TT-4348 M6 put
# it under scripts/sf/ for exactly this reason). Subfolders other than lib/ are not hashed.
harness_sha(){ ( cd "$1" && ls *.sh lib/*.sh lib/*.py 2>/dev/null | grep -v '^loop\.config' | LC_ALL=C sort \
  | while IFS= read -r f; do cat "$f"; done | cksum | cut -d' ' -f1 ); }
