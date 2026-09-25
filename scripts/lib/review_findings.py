#!/usr/bin/env python3
"""review_findings.py — the driver's reader and writer of RENDERED review artifacts (harness 1.8.0).

A reviewer's findings are its structured last message (schemas/findings.json); a verifier's closures
are its structured last message (schemas/verify.json). Nothing in the harness reads prose to decide
whether a finding is open any more — this file renders the JSON into the markdown shapes that
`gate.sh`'s review_scan has always counted, under STABLE IDS, and applies closures in place, in the
artifact that raised the finding. The status line of a rendered artifact is DERIVED from its
findings on every write; a reviewer's `verdict` field that disagrees is reported, never obeyed.

Subcommands (stdout is for the driver's log; a non-zero exit means nothing was written):

  render       <result.json> <artifact> <ms> <round> <dim>
  apply        <result.json> <label> <artifact>...
  verification <result.json> <artifact> <ms> <label>
  open         [--all] <artifact>...
  recurrence   <limit> <rounds_before> <artifact>...   (a path counts only across >= 2 distinct rounds)

`open` prints one line per OPEN blocker/major finding: `<id>\t<file>\t<line>` — id empty for a prose
finding; `--all` includes minors (the verifier brief: a minor costs the same to re-prove, 1.8.3). `recurrence` prints the worst path at or over the limit, or nothing.

The three finding shapes below are review_scan's, deliberately (`[blocker]`/`[major]` anywhere, a
`- blocker` list item, a `blocker:` line), minus its exemptions (`- [x]`, a resolved/closed/fixed
heading that is not negated, `blocker: none`). Two readers of one rule is a defect this harness has
paid for before; the mitigation is that these regexes are copied verbatim from _doc_only_findings in
loop-driver.sh and the kitchen's fixtures feed both the same inputs.
"""
import json
import os
import pathlib
import re
import sys

MARKER = "<!-- rendered by loop-driver.sh from the role's structured output"
# The driver's own steer artifact (`loop-driver.sh steer`, harness 1.8.5) is rendered too: its
# findings carry `s<round>-driver-<k>` ids and are closed by id like any other.
STEER_MARKER = "<!-- rendered by loop-driver.sh steer"
FIND = re.compile(r"\[(?:blocker|major)\]"
                  r"|^\s*-\s+(?:blocker|major)[^a-z]"
                  r"|^\s*[#>*_\-]*\s*(?:blocker|major)\s*:", re.I)
DONE = re.compile(r"^\s*-\s*\[\s*x\s*\]", re.I)
NONE = re.compile(r"(?:blocker|major)\s*:\s*(?:none|0)(?:[^0-9]|$)", re.I)
HEAD = re.compile(r"^#+\s")
CLOSED = re.compile(r"(^|[^a-z])(resolved|closed|fixed)([^a-z]|$)", re.I)
NEGATED = re.compile(r"(^|[^a-z])(not|never|yet|open|outstanding|pending)([^a-z]|$)", re.I)
# The id shape the driver assigns: r<round>-<dim>-<n>, or s<round>-driver-<k> for a driver steer
# (1.8.5). Read right after the checkbox and nowhere else, so a title that happens to mention another
# finding cannot be mistaken for the line's own id.
IDLINE = re.compile(r"^(?P<ind>\s*)- \[(?P<box>[ xX])\] (?P<id>[rs]\d+-[a-z0-9-]+-\d+) \[(?P<sev>[a-z]+)\] (?P<rest>.*)$")
# The same path shape findings_for routes on: dir/file.ext on the finding's own line.
PATH = re.compile(r"(?:^|[^A-Za-z0-9_./-])([A-Za-z0-9_.-]+/[A-Za-z0-9_./-]+\.[A-Za-z0-9]+)")
ROUND = re.compile(r"_round(\d+)_")


def structured(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        d = json.load(f)
    s = d.get("structured_output")
    if not isinstance(s, dict):
        try:
            s = json.loads(d.get("result") or "")
        except Exception:
            s = {}
    return s if isinstance(s, dict) else {}


def one_line(s, cap):
    s = (s or "").replace("\r", "").replace("\n", " ⏎ ").strip()
    s = re.sub(r"\s+", " ", s)
    # Free text never gets to be a finding: `[major]` inside a title or a quoted output would be a
    # second line review_scan counts, so the token is defused wherever it is not the line's own.
    s = re.sub(r"\[(blocker|major|minor)\]", r"(\1)", s, flags=re.I)
    return s if len(s) <= cap else s[: cap - 1] + "…"


def read_lines(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read().splitlines()


def write_lines(path, lines):
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")


def rendered(lines):
    return any(l.startswith(MARKER) or l.startswith(STEER_MARKER) for l in lines[:6])


UNREVIEWED = re.compile(r"^Reviewer status: `(blocked|no_work|refuted)`$")


def derive_status(lines):
    """open when any unticked blocker/major id-line remains, or when the reviewer did not review
    (harness 1.8.8: a `blocked` status stamp over NO finding line - zero findings from a reviewer
    that stopped are not zero defects, and consolidate/gate.sh read only this token); converged
    otherwise."""
    found = False
    for l in lines:
        m = IDLINE.match(l)
        if m:
            found = True
            if m.group("box") == " " and m.group("sev") in ("blocker", "major"):
                return "open"
    if not found and any(UNREVIEWED.match(l) for l in lines):
        return "open"
    return "converged"


def restamp_status(lines):
    st = derive_status(lines)
    for i, l in enumerate(lines):
        if re.match(r"^status:\s", l):
            lines[i] = f"status: {st}"
            return st
    return st


def open_findings(files, all_sev=False):
    """(id, file, line) for every open blocker/major line, prose or rendered; all_sev adds minors."""
    out = []
    for name in files:
        try:
            lines = read_lines(name)
        except OSError:
            continue
        sect = ""
        for l in lines:
            cur = sect
            if HEAD.match(l):
                sect = l
            # FIND matches blocker/major only, because convergence does. With all_sev the severity
            # gate moves to the id line below, so a rendered minor reaches the verifier's brief.
            if not (FIND.search(l) or (all_sev and IDLINE.match(l))) or DONE.match(l) or NONE.search(l):
                continue
            if CLOSED.search(cur) and not NEGATED.search(cur):
                continue
            m = IDLINE.match(l)
            if m and not all_sev and m.group("sev") not in ("blocker", "major"):
                continue
            out.append((m.group("id") if m else "", name, l.strip()))
    return out


def cmd_render(result, artifact, ms, rnd, dim):
    s = structured(result)
    # NO findings[] AT ALL is not "no findings": it is a role that answered another schema — a CLI
    # without --json-schema, a legacy reviewer, a stub. Rendering an empty artifact over the prose it
    # wrote would drop every blocker in that prose from the count, which is a false green. Leave the
    # artifact it wrote to stand, and say so.
    if not isinstance(s.get("findings"), list):
        print("  (no findings[] in the structured output — the artifact the reviewer wrote stands, unrendered)")
        return 0
    findings = s.get("findings") or []
    verdict = s.get("verdict", "")
    status = str(s.get("status") or "")
    tag = dim or "review"
    # A prose artifact the reviewer wrote at the dictated path is kept beside the rendered one,
    # uncounted: `_issues.prose.md` matches none of the `_issues\.md$` selectors.
    if os.path.exists(artifact):
        try:
            if not rendered(read_lines(artifact)):
                os.replace(artifact, artifact[:-3] + ".prose.md")
                print(f"  (kept the reviewer's prose beside it as {os.path.basename(artifact)[:-3]}.prose.md — uncounted)")
        except OSError:
            pass
    lines = [f"# {ms} — review round {rnd} · {tag}",
             f"{MARKER} (schemas/findings.json). Ids are stable; the status line is derived from the findings on every write. Do not edit by hand. -->",
             "", "status: open", "",
             f"Reviewer verdict field: `{verdict or '(absent)'}` · message: {one_line(s.get('message'), 600) or '(none)'}",
             # The reviewer's own status, on its own line (harness 1.8.8): `blocked` over no finding
             # is a reviewer that did not finish, and loop-driver's round_missing_dims owes the
             # dimension again. Its own line, not a `·` field, so the status-token reader in
             # gate.sh (a field that BEGINS with `status`) never mistakes it for the verdict.
             f"Reviewer status: `{status or '(absent)'}`",
             "", "## Findings", ""]
    counts = {"blocker": 0, "major": 0, "minor": 0}
    for i, f in enumerate(findings, 1):
        sev = str(f.get("severity", "major")).lower()
        counts[sev] = counts.get(sev, 0) + 1
        path = one_line(f.get("path"), 200) or "(no path — UNROUTABLE: no role owns this finding)"
        line = f.get("line") or 0
        loc = f"{path}:{line}" if line else path
        title = one_line(f.get("title"), 300) or "(untitled)"
        lines.append(f"- [ ] r{rnd}-{tag}-{i} [{sev}] {loc} — {title}")
        cmd = one_line(f.get("evidence_command"), 400)
        outp = one_line(f.get("observed_output"), 600)
        if cmd or outp:
            lines.append(f"      evidence: `{cmd or '(none)'}` → {outp or '(no output quoted)'}")
        else:
            lines.append("      evidence: NONE GIVEN — a claim, not a measurement; the next round re-proves or refutes it")
    if not findings:
        lines.append("_No findings from this dimension this round._")
    lines.append("")
    st = restamp_status(lines)
    os.makedirs(os.path.dirname(artifact) or ".", exist_ok=True)
    write_lines(artifact, lines)
    n = len(findings)
    print(f"  rendered {n} finding(s) ({counts.get('blocker',0)} blocker, {counts.get('major',0)} major, {counts.get('minor',0)} minor) → {os.path.basename(artifact)} · status: {st}")
    if verdict and verdict != st:
        print(f"  WARN the reviewer's verdict field said `{verdict}`; the findings say `{st}` — the findings decide")
    if not findings and status in ("blocked", "no_work", "refuted"):
        print(f"  WARN the reviewer answered `{status}` with no findings: the dimension is not reviewed, it is OWED (status: open until a reviewer finishes it) - the driver re-runs it at this round (round_missing_dims; RO stops the run when a dimension stops twice within one round)")
    return 0


def cmd_apply(result, label, artifacts):
    s = structured(result)
    vs = s.get("verifications") or []
    if not vs:
        return 0
    files = {}
    for a in artifacts:
        try:
            ls = read_lines(a)
        except OSError:
            continue
        if rendered(ls):
            files[a] = ls
    applied = rejected = unknown = 0
    for v in vs:
        vid = str(v.get("id", "")).strip()
        verdict = str(v.get("verdict", "")).lower()
        cmd = one_line(v.get("evidence_command"), 400)
        outp = one_line(v.get("observed_output"), 600)
        hit = None
        for a, ls in files.items():
            for i, l in enumerate(ls):
                m = IDLINE.match(l)
                if m and m.group("id") == vid:
                    hit = (a, i, m)
                    break
            if hit:
                break
        if not hit:
            unknown += 1
            print(f"  UNKNOWN id `{vid}` ({verdict}) — no rendered artifact of this milestone carries it")
            continue
        a, i, m = hit
        evidence = f"`{cmd}` → {outp}"
        if verdict in ("resolved", "refuted"):
            if cmd and outp:
                files[a][i] = f"{m.group('ind')}- [x] {vid} [{m.group('sev')}] {m.group('rest')} → {verdict} ({label}): {evidence}"
                applied += 1
                print(f"  {verdict}: {vid}")
            else:
                files[a][i] = f"{files[a][i]} · closure REJECTED ({label}): {verdict} without evidence_command + observed_output — stays open"
                rejected += 1
                print(f"  REJECTED closure of {vid}: `{verdict}` without both evidence fields — the finding stays open")
        elif verdict == "open":
            # Missing evidence fails SAFE in both directions: a closure without it is refused above,
            # and an `open` without it still opens — raising the alarm needs no command, lowering it
            # does. The first cut left a ticked box ticked when the reopen came without evidence, so
            # the line read "resolved … · still open" and derived converged (review of #126).
            note = evidence if (cmd or outp) else "no evidence quoted"
            if m.group("box") != " ":
                files[a][i] = f"{m.group('ind')}- [ ] {vid} [{m.group('sev')}] {m.group('rest')} → REOPENED ({label}): {note}"
                print(f"  reopened: {vid}")
            else:
                files[a][i] = f"{files[a][i]} · still open ({label}): {note}"
                print(f"  still open: {vid}")
            applied += 1
        else:
            unknown += 1
            print(f"  UNKNOWN verdict `{verdict}` for {vid}")
    for a, ls in files.items():
        st = restamp_status(ls)
        write_lines(a, ls)
    print(f"  verifications: {applied} applied, {rejected} rejected, {unknown} unknown")
    return 0


def cmd_verification(result, artifact, ms, label):
    s = structured(result)
    vs = s.get("verifications") or []
    lines = [f"# {ms} — {label}",
             f"{MARKER} (schemas/verify.json). Informational record; closures were applied in the artifacts that raised the findings. -->",
             "", f"status: {s.get('status') or '(absent)'} · message: {one_line(s.get('message'), 800) or '(none)'}", "",
             "| id | verdict | evidence |", "|---|---|---|"]
    for v in vs:
        lines.append(f"| {one_line(v.get('id'), 60)} | {one_line(v.get('verdict'), 20)} | `{one_line(v.get('evidence_command'), 200)}` → {one_line(v.get('observed_output'), 300)} |")
    if not vs:
        lines.append("| — | — | the verifier returned no verifications |")
    lines.append("")
    os.makedirs(os.path.dirname(artifact) or ".", exist_ok=True)
    write_lines(artifact, lines)
    print(f"  recorded {len(vs)} verification(s) → {os.path.basename(artifact)}")
    return 0


def cmd_open(files):
    all_sev = False
    if files and files[0] == "--all":
        all_sev, files = True, files[1:]
    for vid, name, line in open_findings(files, all_sev):
        print(f"{vid}\t{name}\t{line[:160]}")
    return 0


def cmd_recurrence(limit, rounds_before, files):
    per = {}
    for name in files:
        m = ROUND.search(os.path.basename(name))
        rnd = int(m.group(1)) if m else 1
        if rnd <= rounds_before:
            continue
        try:
            lines = read_lines(name)
        except OSError:
            continue
        for l in lines:
            if not FIND.search(l) or NONE.search(l) or re.search(r"refut", l, re.I):
                continue
            m2 = IDLINE.match(l)
            if m2 and m2.group("sev") not in ("blocker", "major"):
                continue
            pm = PATH.search(l)
            if not pm:
                continue
            p = pm.group(1)
            label = m2.group("id") if m2 else one_line(l.strip(), 70)
            per.setdefault(p, []).append((rnd, label))
    # Recurrence means ACROSS ROUNDS: three dimensions naming one path in one round is one defect seen
    # from three angles, not a mechanism the loop keeps patching. A path counts only once it has drawn
    # findings in at least two distinct rounds.
    per = {p: hits for p, hits in per.items() if len({r for r, _ in hits}) >= 2}
    worst = max(per.items(), key=lambda kv: len(kv[1]), default=None)
    if not worst or len(worst[1]) < limit:
        return 0
    p, hits = worst
    rounds = sorted({r for r, _ in hits})
    # Bounded: the operator reading a stopped loop needs the shape, not a wall — 360 findings on one
    # path once inlined as one line of ESCALATION.md (review of #126). The artifacts hold the rest.
    shown = hits[:6]
    details = "; ".join(f"r{r}: {lab}" for r, lab in shown)
    if len(hits) > len(shown):
        details += f"; … and {len(hits) - len(shown)} more in review-results/"
    print(f"{p}\t{len(hits)}\t{','.join(str(r) for r in rounds)}\t{details}")
    return 0


def cmd_close(fid, reason, files):
    """The driver closes (1.8.9, TT-4348 M13 §2.4) a finding the owning role refuted and the
    driver accepts as refuted by design - `- [x]`, the reason appended, the status line re-derived.
    The alternative was a hand edit of a rendered artifact, which forgot the status line."""
    for f in files:
        path = pathlib.Path(f)
        if not path.exists():
            continue
        lines = path.read_text(encoding="utf-8").split("\n")
        hit = False
        for i, l in enumerate(lines):
            m = IDLINE.match(l)
            if m and m.group("id") == fid and m.group("box") == " ":
                lines[i] = l.replace("- [ ] ", "- [x] ", 1) + f" · CLOSED by the driver: {reason}"
                hit = True
        if hit:
            st = restamp_status(lines)
            path.write_text("\n".join(lines), encoding="utf-8")
            print(f"  closed {fid} in {f} - status: {st}")
            return 0
    print(f"  {fid}: no open line in {len(files)} artifact(s)", file=sys.stderr)
    return 1


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    cmd, args = argv[1], argv[2:]
    if cmd == "render" and len(args) == 5:
        return cmd_render(args[0], args[1], args[2], args[3], args[4])
    if cmd == "apply" and len(args) >= 2:
        return cmd_apply(args[0], args[1], args[2:])
    if cmd == "verification" and len(args) == 4:
        return cmd_verification(args[0], args[1], args[2], args[3])
    if cmd == "open":
        return cmd_open(args)
    if cmd == "close" and len(args) >= 3:
        return cmd_close(args[0], args[1], args[2:])
    if cmd == "recurrence" and len(args) >= 2:
        return cmd_recurrence(int(args[0]), int(args[1]), args[2:])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
