#!/usr/bin/env python3
"""
Filter and sort Ubuntu packages from a list file.

This script reads a list of packages and:
1. Removes commented lines
2. Checks if each package exists in Ubuntu repositories
3. Deduplicates packages (optional)
4. Sorts the valid packages alphabetically
5. Outputs the filtered and sorted list

Usage:
    python3 filter_packages.py <input_file> [output_file] [--keep-duplicates]

    Use --keep-duplicates to preserve duplicate entries (default removes them)
"""

import sys
import re
import subprocess
from pathlib import Path
from typing import Set, List

try:
    import apt
except ImportError:
    print("Error: python3-apt is not installed.", file=sys.stderr)
    print("Install it with: sudo apt-get install python3-apt", file=sys.stderr)
    sys.exit(1)


def read_packages(file_path: str) -> List[str]:
    """Read packages from file, stripping comments and whitespace.

    Handles both single package per line and space-separated packages.
    """
    packages = []
    with open(file_path, "r") as f:
        for line in f:
            # Strip whitespace
            line = line.strip()

            # Skip empty lines
            if not line:
                continue

            # Skip comment lines (starting with #)
            if line.startswith("#"):
                continue

            # Skip inline comments by taking everything before #
            line = line.split("#")[0].strip()

            # Skip if result is empty
            if not line:
                continue

            # Split by whitespace to handle multiple packages on one line
            for package in line.split():
                if package:
                    packages.append(package)

    return packages


def check_package_exists(package: str, cache: apt.cache.Cache) -> bool:
    """Check if package exists in apt cache."""
    try:
        return package in cache
    except Exception:
        return False


def filter_and_sort_packages(packages: List[str]) -> tuple[List[str], List[str]]:
    """
    Filter packages against Ubuntu repositories and sort.
    Returns (valid_packages, invalid_packages)
    """
    try:
        # Open apt cache
        cache = apt.cache.Cache()
    except Exception as e:
        print(f"Error opening apt cache: {e}", file=sys.stderr)
        print("Make sure apt cache is available.", file=sys.stderr)
        sys.exit(1)

    valid = []
    invalid = []

    print(f"Checking {len(packages)} packages...", file=sys.stderr)

    for i, package in enumerate(packages):
        if (i + 1) % 50 == 0:
            print(f"  Progress: {i + 1}/{len(packages)}", file=sys.stderr)

        if check_package_exists(package, cache):
            valid.append(package)
        else:
            invalid.append(package)

    # Sort both lists alphabetically
    valid.sort()
    invalid.sort()

    return valid, invalid


def format_output(packages: List[str]) -> str:
    """Format packages as tab-indented list."""
    return "\n".join(f"\t{pkg}" for pkg in packages)


def main():
    if len(sys.argv) < 2:
        print(
            "Usage: python3 filter_packages.py <input_file> [output_file] [--keep-duplicates]",
            file=sys.stderr,
        )
        print("If output_file is not specified, prints to stdout", file=sys.stderr)
        print("Use --keep-duplicates to preserve duplicate entries", file=sys.stderr)
        sys.exit(1)

    input_file = sys.argv[1]
    output_file = None
    keep_duplicates = False

    # Parse arguments
    for arg in sys.argv[2:]:
        if arg == "--keep-duplicates":
            keep_duplicates = True
        else:
            output_file = arg

    # Read packages from input file
    try:
        packages = read_packages(input_file)
    except FileNotFoundError:
        print(f"Error: File not found: {input_file}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"Error reading file: {e}", file=sys.stderr)
        sys.exit(1)

    print(f"Read {len(packages)} packages from {input_file}", file=sys.stderr)

    # Filter and sort
    valid, invalid = filter_and_sort_packages(packages)

    # Deduplicate if not keeping duplicates
    if not keep_duplicates:
        original_count = len(valid)
        valid = sorted(list(set(valid)))
        if original_count != len(valid):
            print(
                f"  Removed {original_count - len(valid)} duplicates", file=sys.stderr
            )

    # Print summary
    print(f"\nResults:", file=sys.stderr)
    print(f"  Valid packages: {len(valid)}", file=sys.stderr)
    print(f"  Invalid packages: {len(invalid)}", file=sys.stderr)

    if invalid:
        print(f"\nInvalid packages (not in repositories):", file=sys.stderr)
        for pkg in invalid:
            print(f"  - {pkg}", file=sys.stderr)

    # Format output
    output = format_output(valid)

    # Write output
    if output_file:
        try:
            with open(output_file, "w") as f:
                f.write(output + "\n")
            print(f"\nSorted valid packages written to: {output_file}", file=sys.stderr)
        except Exception as e:
            print(f"Error writing to file: {e}", file=sys.stderr)
            sys.exit(1)
    else:
        print("\n--- Sorted Valid Packages ---", file=sys.stderr)
        print(output)


if __name__ == "__main__":
    main()
