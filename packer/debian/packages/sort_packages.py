#!/usr/bin/env python3
"""
Sort package classes and the packages within each class.

Usage:
  python3 sort_packages.py -i packages/list        # print sorted output to stdout
  python3 sort_packages.py -i packages/list -o out # write to out
  python3 sort_packages.py -i packages/list -w     # overwrite input file

Behavior:
- Lines starting with '#' are treated as class headers.
- Non-empty non-header lines are package names belonging to the current header.
- If packages appear before any header, they are placed under 'Uncategorized'.
- Classes are sorted alphabetically; package lists are deduplicated and sorted.
"""

from __future__ import annotations

import argparse
import sys
from collections import defaultdict
from pathlib import Path


def parse_packages(lines):
    groups = defaultdict(list)
    current = "Uncategorized"
    for raw in lines:
        line = raw.rstrip("\n")
        s = line.strip()
        if not s:
            continue
        if s.startswith("#"):
            # treat header line
            header = s.lstrip("#").strip()
            if header == "":
                # blank comment, ignore
                continue
            current = header
            if current not in groups:
                groups[current] = []
        else:
            groups[current].append(s)
    return groups


def sorted_output(groups: dict) -> str:
    out_lines = []
    for header in sorted(groups.keys(), key=str.casefold):
        out_lines.append(f"# {header}")
        # dedupe and sort packages
        pkgs = sorted(set(groups[header]), key=str.casefold)
        for p in pkgs:
            out_lines.append(p)
        out_lines.append("")
    # remove trailing blank line
    if out_lines and out_lines[-1] == "":
        out_lines.pop()
    return "\n".join(out_lines) + "\n"


def find_global_duplicates(groups: dict) -> dict:
    """Return a mapping package -> sorted list of headers where it appears (only those in >1 header)."""
    seen = {}
    for header, pkgs in groups.items():
        for p in set(pkgs):
            seen.setdefault(p, set()).add(header)
    return {
        p: sorted(list(headers), key=str.casefold)
        for p, headers in seen.items()
        if len(headers) > 1
    }


def main():
    p = argparse.ArgumentParser(description="Sort package classes and packages")
    p.add_argument("-i", "--input", required=True, help="input file (use - for stdin)")
    p.add_argument("-o", "--output", help="output file (default stdout)")
    p.add_argument("-w", "--inplace", action="store_true", help="overwrite input file")
    p.add_argument(
        "--report-duplicates",
        action="store_true",
        help="print packages that appear in multiple classes to stderr",
    )
    p.add_argument(
        "--fail-on-duplicates",
        action="store_true",
        help="exit with non-zero status when duplicates are found",
    )
    args = p.parse_args()

    if args.inplace and args.output:
        p.error("Use either --inplace or --output, not both")

    if args.input == "-":
        lines = sys.stdin.readlines()
    else:
        path = Path(args.input)
        if not path.exists():
            sys.exit(f"Input file not found: {args.input}")
        lines = path.read_text(encoding="utf-8").splitlines(True)

    groups = parse_packages(lines)
    duplicates = find_global_duplicates(groups)
    if duplicates and (args.report_duplicates or args.fail_on_duplicates):
        # print duplicates to stderr
        sys.stderr.write("Detected packages present in multiple classes:\n")
        for pkg in sorted(duplicates.keys(), key=str.casefold):
            where = ", ".join(duplicates[pkg])
            sys.stderr.write(f"- {pkg}: {where}\n")
        sys.stderr.flush()
    if duplicates and args.fail_on_duplicates:
        sys.exit(2)
    result = sorted_output(groups)

    if args.inplace:
        Path(args.input).write_text(result, encoding="utf-8")
    elif args.output:
        Path(args.output).write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)


if __name__ == "__main__":
    main()
