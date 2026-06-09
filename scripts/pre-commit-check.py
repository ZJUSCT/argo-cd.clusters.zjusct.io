#!/usr/bin/env python3
"""Pre-commit checks for Kustomize + Helm GitOps repository."""

import sys
import subprocess
from pathlib import Path
from typing import Dict, List, Tuple, Optional

# Allow importing sibling module without package setup
sys.path.insert(0, str(Path(__file__).resolve().parent))
from version_utils import load_yaml


class Checker:
    """Main checker class."""

    def __init__(self, auto_fix: bool = False):
        self.auto_fix = auto_fix
        self.errors: List[str] = []
        self.warnings: List[str] = []
        self.fixes: List[str] = []

    def run_command(self, cmd: List[str], timeout: int = 10) -> Tuple[int, str, str]:
        """Run a shell command and return exit code, stdout, stderr."""
        try:
            result = subprocess.run(
                cmd, capture_output=True, text=True, check=False, timeout=timeout
            )
            return result.returncode, result.stdout, result.stderr
        except subprocess.TimeoutExpired:
            return 1, "", f"Command timeout after {timeout}s"
        except FileNotFoundError:
            return 1, "", f"Command not found: {cmd[0]}"

    def save_yaml(self, file_path: Path, data: Dict) -> bool:
        """Save data to YAML file."""
        try:
            import yaml
            with open(file_path, 'w') as f:
                yaml.dump(data, f, default_flow_style=False, sort_keys=False)
            return True
        except Exception as e:
            print(f"  Error saving {file_path}: {e}")
            return False

    def fix_helm_chart(self, chart: Dict, app_name: str, kustomization_file: Path, kustomization_data: Dict) -> bool:
        """Auto-fix helm chart configuration. Returns True if modified."""
        import yaml
        modified = False
        name = chart.get("name", "unknown")
        repo = chart.get("repo")
        version = chart.get("version")

        # Get top-level namespace from kustomization
        kustomization_namespace = kustomization_data.get("namespace")

        # Fix namespace - must match kustomization namespace
        if kustomization_namespace:
            current_namespace = chart.get("namespace")
            if current_namespace != kustomization_namespace:
                chart["namespace"] = kustomization_namespace
                if current_namespace:
                    self.fixes.append(
                        f"  {app_name}: Chart '{name}' - changed namespace: {current_namespace} -> {kustomization_namespace}"
                    )
                else:
                    self.fixes.append(
                        f"  {app_name}: Chart '{name}' - added namespace: {kustomization_namespace}"
                    )
                modified = True

        # Fix includeCRDs - must be true
        if chart.get("includeCRDs") is not True:
            chart["includeCRDs"] = True
            self.fixes.append(f"  {app_name}: Chart '{name}' - set includeCRDs: true")
            modified = True

        # Fix valuesFile - must be values/<name>-<version>.yaml
        if version:
            expected_values_file = f"values/{name}-{version}.yaml"
            current_values_file = chart.get("valuesFile")

            if current_values_file != expected_values_file:
                chart["valuesFile"] = expected_values_file
                if current_values_file:
                    self.fixes.append(
                        f"  {app_name}: Chart '{name}' - changed valuesFile: {current_values_file} -> {expected_values_file}"
                    )
                else:
                    self.fixes.append(
                        f"  {app_name}: Chart '{name}' - set valuesFile: {expected_values_file}"
                    )
                modified = True

        return modified

    def check_helm_chart_fields(self, chart: Dict, idx: int, app_name: str,
                                kustomization_file: Path, kustomization_data: Dict) -> bool:
        """Check required fields. Returns True if valid."""
        name = chart.get("name", f"chart-{idx}")
        repo = chart.get("repo")
        version = chart.get("version")

        # Get top-level namespace from kustomization
        kustomization_namespace = kustomization_data.get("namespace")

        # Check repo and version consistency
        if (repo and not version) or (version and not repo):
            # Exception: local charts don't need repo
            if not repo and not version:
                # This is a local chart, OK
                pass
            else:
                self.errors.append(
                    f"  {app_name}: Chart '{name}' - repo and version must both exist or both be absent"
                )
                return False

        # Check required fields
        required = [
            "name",
            "releaseName",
            "namespace",
            "includeCRDs",
            "valuesFile"
        ]

        has_error = False
        for field in required:
            if field not in chart or chart[field] is None or chart[field] == "":
                self.errors.append(f"  {app_name}: Chart '{name}' missing '{field}'")
                has_error = True

        # Check namespace matches kustomization namespace
        if kustomization_namespace and chart.get("namespace"):
            if chart["namespace"] != kustomization_namespace:
                self.errors.append(
                    f"  {app_name}: Chart '{name}' - namespace must be '{kustomization_namespace}' (found: '{chart['namespace']}')"
                )
                has_error = True

        # Check includeCRDs is true
        if "includeCRDs" in chart and chart["includeCRDs"] is not True:
            self.errors.append(
                f"  {app_name}: Chart '{name}' - includeCRDs must be true"
            )
            has_error = True

        # Check valuesFile format
        if version and chart.get("valuesFile"):
            expected_values_file = f"values/{name}-{version}.yaml"
            if chart["valuesFile"] != expected_values_file:
                self.errors.append(
                    f"  {app_name}: Chart '{name}' - valuesFile must be '{expected_values_file}' (found: '{chart['valuesFile']}')"
                )
                has_error = True

        return not has_error

    def check_kustomize_build(self, app_dir: Path, app_name: str) -> None:
        """Test if kustomize can successfully build the manifests."""
        code, _, stderr = self.run_command(
            ["kubectl", "kustomize", "--enable-helm", "--load-restrictor=LoadRestrictionsNone", str(app_dir)],
            timeout=30
        )
        if code != 0:
            self.errors.append(f"  {app_name}: Kustomize build failed\n{stderr}")

    def check_app_directory(self, app_dir: Path, repo_root: Path) -> bool:
        """Check a single application directory. Returns True if passed."""
        kustomization_file = app_dir / "kustomization.yaml"
        if not kustomization_file.exists():
            return True

        app_name = str(app_dir.relative_to(repo_root))
        print(f"\n{app_name}")

        # Load kustomization.yaml
        kustomization_data = load_yaml(kustomization_file)
        if not kustomization_data:
            self.errors.append(f"  {app_name}: Failed to load kustomization.yaml")
            return False

        charts = kustomization_data.get("helmCharts", [])
        if not charts:
            print("  No helm charts")
            # Still check kustomize build
            self.check_kustomize_build(app_dir, app_name)
            return len(self.errors) == 0

        modified = False

        # Check each chart
        for idx, chart in enumerate(charts):
            name = chart.get("name", f"chart-{idx}")
            print(f"  Chart: {name}")

            # Check required fields (and auto-fix if enabled)
            chart_modified = self.auto_fix and self.fix_helm_chart(chart, app_name, kustomization_file, kustomization_data)
            if chart_modified:
                modified = True

            self.check_helm_chart_fields(chart, idx, app_name,
                                         kustomization_file, kustomization_data)

        # Save kustomization.yaml if modified
        if self.auto_fix and modified:
            if self.save_yaml(kustomization_file, kustomization_data):
                print(f"  Fixed and saved {kustomization_file.name}")

        # Check kustomize build
        self.check_kustomize_build(app_dir, app_name)

        return len(self.errors) == 0

    def run_checks(self, repo_root: Path, files: Optional[List[str]] = None) -> int:
        """Run checks on application directories affected by changed files.

        When *files* is provided (from pre-commit), only the kustomization app
        directories that own those files are checked.  When *files* is absent
        or empty all directories under dev/ and production/ are checked.
        """
        if files:
            app_dirs = get_app_dirs_from_files(files, repo_root)
        else:
            app_dirs = []
            # Fall back: check all directories in dev/ and production/
            for env in ["dev", "production"]:
                env_path = repo_root / env
                if env_path.exists():
                    for app_dir in sorted(env_path.iterdir()):
                        if app_dir.is_dir() and (app_dir / "kustomization.yaml").exists():
                            app_dirs.append(app_dir)

        if not app_dirs:
            print("No application directories to check")
            return 0

        print(f"Checking {len(app_dirs)} applications...")

        # Check each directory
        for app_dir in app_dirs:
            self.check_app_directory(app_dir, repo_root)

        # Print fixes
        if self.fixes:
            print("\n" + "=" * 80)
            print("FIXES APPLIED:")
            for fix in self.fixes:
                print(fix)

        # Print warnings
        if self.warnings:
            print("\n" + "=" * 80)
            print("WARNINGS:")
            for warning in self.warnings:
                print(warning)

        # Print summary
        print("\n" + "=" * 80)
        if self.errors:
            print("FAILED - Errors found:")
            for error in self.errors:
                print(error)
            return 1
        else:
            print("PASSED - All checks successful")
            return 0


def get_git_root() -> Path:
    """Get the root directory of the git repository."""
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True, text=True, check=True
        )
        return Path(result.stdout.strip())
    except (subprocess.CalledProcessError, FileNotFoundError):
        return Path.cwd()


def get_app_dirs_from_files(files: List[str], repo_root: Path) -> List[Path]:
    """Derive unique app directories from a list of changed file paths.

    Walks up from each file to find the nearest ancestor that contains a
    kustomization.yaml, stopping before the repo root.
    """
    app_dirs: set = set()
    for file_str in files:
        file_path = Path(file_str)
        if not file_path.is_absolute():
            file_path = repo_root / file_path
        candidate = file_path if file_path.is_dir() else file_path.parent
        while candidate != repo_root and candidate != candidate.parent:
            if (candidate / "kustomization.yaml").exists():
                app_dirs.add(candidate)
                break
            candidate = candidate.parent
    return sorted(app_dirs)


def main():
    """Main entry point."""
    import argparse
    parser = argparse.ArgumentParser(description="Pre-commit checks for Kustomize + Helm")
    parser.add_argument(
        "--fix",
        action="store_true",
        help="Automatically fix issues (add missing fields)"
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Changed files passed by pre-commit (limits checks to affected apps)"
    )
    args = parser.parse_args()

    repo_root = get_git_root()
    checker = Checker(auto_fix=args.fix)
    return checker.run_checks(repo_root, files=args.files)


if __name__ == "__main__":
    sys.exit(main())
