#!/usr/bin/env bash
# DRIVER: publish milestone progress → managed README block (file-only; idempotent, bash-3.2/BSD safe).
# Jira comment + Notion section = driver MCP steps (SKILL "Progress Sync"), not this script.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"; ROOT="$(cd "$HERE/.." && pwd)"
source "$HERE/loop.config"; cd "$ROOT"
MN="${1:?usage: sync-progress.sh <Mn> <status>}"; STATUS="${2:?status}"
[ "${SYNC_README:-true}" = true ] || { echo "sync-progress: SYNC_README off — skip"; exit 0; }
README="${README_PATH:-./README.md}"; PLAN="$SPEC_DIR/TDD_PLAN.md"
name="$(grep -E "^###[[:space:]]+$MN[[:space:]]+—" "$PLAN" 2>/dev/null | head -1 | sed -E "s/^###[[:space:]]+$MN[[:space:]]+—[[:space:]]*//; s/[[:space:]]*\(.*//")"
[ -n "$name" ] || name="$MN"
pr="$(gh pr view --json number -q '.number' 2>/dev/null || true)"; [ -n "$pr" ] && pr="#$pr" || pr='—'
case "$STATUS" in
  Done|done)            icon='✅ Done';;
  "In Review"|*Review*) icon='🔍 In Review';;
  *)                    icon="⏳ $STATUS";;
esac
row="| $MN | $name | $icon | $pr |"
rows="$(mktemp)"; blk="$(mktemp)"
if grep -qF '<!-- loop:progress:start -->' "$README" 2>/dev/null; then
  awk '/<!-- loop:progress:start -->/{s=1;next}/<!-- loop:progress:end -->/{s=0}s' "$README" \
    | grep -E '^\| M[0-9]+ ' | grep -vE "^\| $MN " > "$rows" || true
fi
echo "$row" >> "$rows"
sorted="$(while IFS= read -r r; do [ -z "$r" ] && continue
  num="$(printf '%s' "$r" | sed -E 's/^\| M([0-9]+).*/\1/')"
  printf '%06d\t%s\n' "${num:-0}" "$r"
done < "$rows" | sort | cut -f2-)"
{ echo '<!-- loop:progress:start -->'; echo '## Milestone Progress'
  echo '| Mn | Value | Status | PR |'; echo '|----|-------|--------|----|'
  printf '%s\n' "$sorted"; echo '<!-- loop:progress:end -->'; } > "$blk"
if [ ! -f "$README" ]; then cat "$blk" > "$README"
elif grep -qF '<!-- loop:progress:start -->' "$README"; then
  awk -v f="$blk" '/<!-- loop:progress:start -->/{while((getline l<f)>0)print l;close(f);s=1;next}/<!-- loop:progress:end -->/{s=0;next}!s' "$README" > "$README.tmp" && mv "$README.tmp" "$README"
else { echo; cat "$blk"; } >> "$README"; fi
rm -f "$rows" "$blk"
echo "sync-progress: $MN → $icon ($pr) written to $README"
