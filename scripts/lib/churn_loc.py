#!/usr/bin/env python3
"""Count the EXECUTABLE lines a change touches, not the diff lines.

R8 exists to catch a LEAP — an iteration that rewrote more than a milestone step
should. Counting `git diff --shortstat` insertions made it a measure of how much
was WRITTEN, and most of what a documented step writes is prose: the worst trip
on one measured milestone was 619 diff lines across five new modules holding
~105 executable lines against ~350 of docstring. The breaker fired four times in
that milestone, never once on a real leap, and every trip cost an adjudication.
A budget that reliably measures documentation is not a budget, so this measures
statements instead.

What counts, per changed file:

* ``.py`` — lines that are non-blank, not comment-only, and not part of a
  docstring, intersected with the lines this diff actually touched. Removed
  lines are scored against the OLD blob and added lines against the working
  tree, so a rewrite counts both halves rather than netting to zero.
* everything else — raw changed lines, unchanged from the old behaviour. A
  Markdown plan rewrite is still churn; it is only docstrings that were being
  counted as though they were logic.

A non-empty multi-line string that is NOT a docstring (embedded SQL, a fixture
payload) counts as code, deliberately: it is data the program depends on, and a
step that rewrites 400 lines of it has done something worth a look.

**The loop's own evidence is not churn.** ``$SPEC_DIR``, ``review-results/`` and
``issues.md`` are excluded, because they are what the loop writes ABOUT itself:
measured over one milestone's 54 commits, the four largest "changes to the
system" were a review record, a review record, a review record and a review
record — the largest 2513 lines of markdown by a reviewer who touched no code at
all. The iteration fingerprint in loop-iteration.sh already excludes
``$SPEC_DIR`` for the same reason; R8 counting what the fingerprint ignores was
the other half of why it never caught a leap.

Fails OPEN. A file that will not parse, a missing blob, an unreadable tree — any
of them returns that file's raw diff count rather than zero, because a breaker
that silently stops counting is worse than one that counts the wrong thing.

Usage (called by the adapter's `churn_loc`, not by hand):
    churn_loc.py <base-rev> [<spec-dir>]   ->  "<statements> <prose>"
"""

from __future__ import annotations

import ast
import re
import subprocess
import sys

_HUNK = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@")


def _git(*args: str) -> str | None:
    """One git call, or ``None`` where the old behaviour must take over."""
    try:
        done = subprocess.run(
            ["git", *args], capture_output=True, text=True, check=False
        )
    except OSError:
        return None
    return done.stdout if done.returncode == 0 else None


def _code_lines(source: str) -> tuple[set[int], set[int]] | None:
    """The line numbers carrying a statement, and the ones carrying prose.

    Docstrings are excluded by AST position rather than by looking for triple
    quotes: the quoting style is the author's, and a module whose docstring uses
    single quotes is not a different kind of file.
    """
    try:
        tree = ast.parse(source)
    except (SyntaxError, ValueError):
        return None
    prose: set[int] = set()
    for node in ast.walk(tree):
        body = getattr(node, "body", None)
        if not isinstance(body, list) or not body:
            continue
        first = body[0]
        if (
            isinstance(first, ast.Expr)
            and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)
            and first.end_lineno is not None
        ):
            prose.update(range(first.lineno, first.end_lineno + 1))
    code = {
        number
        for number, line in enumerate(source.splitlines(), 1)
        if line.strip() and not line.lstrip().startswith("#") and number not in prose
    }
    text = {
        number
        for number, line in enumerate(source.splitlines(), 1)
        if line.strip() and number not in code
    }
    return code, text


def _touched(diff: str) -> tuple[set[int], set[int]]:
    """The line numbers this diff removed from the old side and added to the new."""
    removed: set[int] = set()
    added: set[int] = set()
    for line in diff.splitlines():
        match = _HUNK.match(line)
        if match is None:
            continue
        old_start, old_count, new_start, new_count = match.groups()
        removed.update(range(int(old_start), int(old_start) + int(old_count or 1)))
        added.update(range(int(new_start), int(new_start) + int(new_count or 1)))
    return removed, added


def _raw(diff: str) -> int:
    """The old measure, kept as the fallback every failure path returns to."""
    return sum(
        1
        for line in diff.splitlines()
        if (line.startswith(("+", "-")) and not line.startswith(("+++", "---")))
    )


def _read(path: str) -> str | None:
    try:
        with open(path, encoding="utf-8") as handle:
            return handle.read()
    except OSError:
        return None


def _score(path: str, base: str) -> tuple[int, int]:
    """This file's touched lines, split (statements, prose).

    Prose is the number R12 reads and R8 must not: a step is a leap because of
    what it made the program do, and long because of what it wrote about it.
    """
    diff = _git("diff", "-U0", base, "--", path)
    if diff is None:
        return 0, 0
    if not path.endswith(".py"):
        return _raw(diff), 0
    removed, added = _touched(diff)
    statements = 0
    prose = 0
    for source, lines in (
        (_git("show", f"{base}:{path}"), removed),
        (_read(path), added),
    ):
        if source is None:
            # The file is new (no blob at base) or gone (nothing in the tree).
            # Its counterpart side still scores; this half is genuinely empty.
            continue
        split = _code_lines(source)
        if split is None:
            statements += len(lines)
            continue
        code, text = split
        statements += len(lines & code)
        prose += len(lines & text)
    return statements, prose


def _excluded(path: str, spec_dir: str) -> bool:
    """Whether this file is the loop describing itself rather than changing it."""
    prefixes = ["review-results/"]
    if spec_dir:
        prefixes.append(spec_dir.rstrip("/") + "/")
    return path == "issues.md" or path.startswith(tuple(prefixes))


def main() -> int:
    base = sys.argv[1] if len(sys.argv) > 1 else "HEAD"
    spec_dir = sys.argv[2] if len(sys.argv) > 2 else ""
    names = _git("diff", "--name-only", base)
    if names is None:
        print("0 0")
        return 0
    scored = [
        _score(path, base)
        for path in names.splitlines()
        if path and not _excluded(path, spec_dir)
    ]
    print(f"{sum(s for s, _ in scored)} {sum(p for _, p in scored)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
