#!/usr/bin/env python3
"""Pre-commit checks for Kustomize + Helm GitOps repository."""

import sys
import subprocess
import re
import json
import urllib.request
import urllib.error
import time
from pathlib import Path
from typing import Dict, List, Tuple, Optional
from urllib.parse import urlparse

try:
    import yaml
except ImportError:
    print("Error: PyYAML not installed. Install with: pip install pyyaml")
    sys.exit(1)


class Checker:
    """Main checker class."""

    def __init__(self, auto_fix: bool = False, update_versions: bool = False):
        self.auto_fix = auto_fix
        self.update_versions = update_versions
        self.version_cache: Dict[Tuple[str, str], Optional[str]] = {}
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

    def load_yaml(self, file_path: Path) -> Optional[Dict]:
        """Load and parse YAML file."""
        try:
            with open(file_path, 'r') as f:
                return yaml.safe_load(f)
        except FileNotFoundError:
            return None
        except yaml.YAMLError as e:
            print(f"  Error parsing {file_path}: {e}")
            return None

    def save_yaml(self, file_path: Path, data: Dict) -> bool:
        """Save data to YAML file."""
        try:
            with open(file_path, 'w') as f:
                yaml.dump(data, f, default_flow_style=False, sort_keys=False)
            return True
        except Exception as e:
            print(f"  Error saving {file_path}: {e}")
            return False

    def get_latest_version_http(self, chart_name: str, repo_url: str) -> Optional[str]:
        """Get latest version from HTTP Helm repository."""
        try:
            # Ensure repo_url ends with /
            if not repo_url.endswith('/'):
                repo_url += '/'

            index_url = repo_url + 'index.yaml'

            # Create request with User-Agent (some servers require it)
            req = urllib.request.Request(index_url)
            req.add_header('User-Agent', 'helm-chart-validator/1.0')

            with urllib.request.urlopen(req, timeout=10) as response:
                index_data = yaml.safe_load(response.read())

            entries = index_data.get('entries', {})
            chart_entries = entries.get(chart_name, [])

            if not chart_entries:
                print(f"chart not found in index")
                return None

            # Get the first entry (should be the latest)
            latest = chart_entries[0]
            return latest.get('version')

        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code} {e.reason}")
            print(f"      URL: {index_url}")
            print(f"      Headers: {dict(e.headers)}")
            return None
        except urllib.error.URLError as e:
            print(f"connection failed: {e.reason}")
            return None
        except yaml.YAMLError as e:
            print(f"YAML parse error: {e}")
            return None
        except KeyError as e:
            print(f"missing key: {e}")
            return None
        except Exception as e:
            print(f"unexpected error: {e}")
            return None

    def get_oci_auth_token(self, registry: str, repository: str, max_retries: int = 2) -> Tuple[Optional[str], Optional[str]]:
        """Get authentication token for OCI registry with retries. Returns (token, error)."""
        # Determine auth service and realm based on registry
        if 'docker.io' in registry or registry == 'registry-1.docker.io':
            auth_url = "https://auth.docker.io/token"
            service = "registry.docker.io"
            # Docker Hub uses 'library/' prefix for official images
            if '/' not in repository:
                repository = f"library/{repository}"
        else:
            # Generic OCI registry, try without auth first
            return None, None

        # Request token with pull scope
        scope = f"repository:{repository}:pull"
        token_url = f"{auth_url}?service={service}&scope={scope}"

        last_error = None
        for attempt in range(max_retries):
            try:
                req = urllib.request.Request(token_url)
                req.add_header('User-Agent', 'helm-chart-validator/1.0')

                with urllib.request.urlopen(req, timeout=20) as response:
                    data = json.loads(response.read())
                    token = data.get('token')
                    if token:
                        return token, None
                    else:
                        return None, "No token in response"

            except urllib.error.URLError as e:
                last_error = f"network error: {e.reason}"
                if attempt < max_retries - 1:
                    time.sleep(1)  # Brief wait before retry
                    continue
            except Exception as e:
                last_error = f"auth error: {e}"
                if attempt < max_retries - 1:
                    time.sleep(1)
                    continue

        return None, last_error

    def get_latest_version_oci(self, chart_name: str, repo_url: str) -> Optional[str]:
        """Get latest version from OCI Helm repository."""
        try:
            # Parse OCI URL: oci://registry.example.com/charts
            parsed = urlparse(repo_url)
            if parsed.scheme != 'oci':
                return None

            # registry.example.com
            registry = parsed.netloc
            # /charts -> charts (remove leading and trailing slashes)
            repository = parsed.path.strip('/')

            # Construct the full image name
            if repository:
                image = f"{repository}/{chart_name}"
            else:
                image = chart_name

            # Map common registries to their API endpoints
            if registry == 'registry-1.docker.io' or 'docker.io' in registry:
                api_registry = 'registry-1.docker.io'
            else:
                api_registry = registry

            # For Docker Hub, add 'library/' prefix for official images
            docker_image = image
            if api_registry == 'registry-1.docker.io' and '/' not in image:
                docker_image = f"library/{image}"

            # Try to get auth token
            token, auth_error = self.get_oci_auth_token(api_registry, docker_image)

            # If auth failed for Docker Hub, we can't proceed (401 will happen)
            if api_registry == 'registry-1.docker.io' and not token:
                if auth_error:
                    print(f"auth failed: {auth_error}")
                else:
                    print(f"auth failed: no token")
                return None

            # Construct tags URL
            tags_url = f"https://{api_registry}/v2/{docker_image}/tags/list"

            req = urllib.request.Request(tags_url)
            req.add_header('Accept', 'application/json')
            req.add_header('User-Agent', 'helm-chart-validator/1.0')

            if token:
                req.add_header('Authorization', f'Bearer {token}')

            with urllib.request.urlopen(req, timeout=10) as response:
                data = json.loads(response.read())

            tags = data.get('tags', [])
            if not tags:
                print(f"no tags found")
                return None

            # Filter out non-version tags and sort semantically
            version_tags = []
            for tag in tags:
                # Match semantic versions like 1.2.3, v1.2.3
                if re.match(r'^v?\d+\.\d+\.\d+', tag):
                    version_tags.append(tag)

            if not version_tags:
                print(f"no version tags found")
                return None

            # Sort versions (simple lexicographic sort for now)
            # For proper semantic versioning, we'd need to parse and compare
            version_tags.sort(reverse=True)
            return version_tags[0]

        except urllib.error.HTTPError as e:
            print(f"HTTP {e.code} {e.reason}")
            print(f"      URL: {tags_url if 'tags_url' in locals() else 'N/A'}")
            if 'docker_image' in locals():
                print(f"      Image: {docker_image}")
            return None
        except urllib.error.URLError as e:
            print(f"connection failed: {e.reason}")
            return None
        except json.JSONDecodeError as e:
            print(f"JSON parse error: {e}")
            return None
        except Exception as e:
            print(f"unexpected error: {e}")
            return None

    def get_latest_version(self, chart_name: str, repo_url: str) -> Optional[str]:
        """Get latest version of a Helm chart from repository."""
        # Skip version fetching if update_versions is not enabled
        if not self.update_versions:
            return None

        cache_key = (chart_name, repo_url)
        if cache_key in self.version_cache:
            return self.version_cache[cache_key]

        print(f"    Fetching version for {chart_name}...", end=" ", flush=True)

        version = None

        # Detect repository type
        if repo_url.startswith('oci://'):
            version = self.get_latest_version_oci(chart_name, repo_url)
        elif repo_url.startswith('http://') or repo_url.startswith('https://'):
            version = self.get_latest_version_http(chart_name, repo_url)
        else:
            print("unknown protocol")

        if version:
            print(f"done ({version})")
        else:
            print("failed")

        self.version_cache[cache_key] = version
        return version

    def fix_helm_chart(self, chart: Dict, app_name: str, kustomization_file: Path, kustomization_data: Dict) -> bool:
        """Auto-fix helm chart configuration. Returns True if modified."""
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

        # Fix version if repo exists but version doesn't
        if repo and not version:
            latest = self.get_latest_version(name, repo)
            if latest:
                chart["version"] = latest
                version = latest
                self.fixes.append(f"  {app_name}: Chart '{name}' - added version: {latest}")
                modified = True
            else:
                self.errors.append(
                    f"  {app_name}: Chart '{name}' - failed to fetch version"
                )

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

    def check_version_update(self, chart: Dict, app_name: str) -> None:
        """Check if a newer version is available."""
        # Skip version update check if not enabled
        if not self.update_versions:
            return

        name = chart.get("name")
        current_version = chart.get("version")
        repo = chart.get("repo")

        if not all([name, current_version, repo]):
            return

        latest = self.get_latest_version(name, repo)
        if latest and latest != current_version:
            # Normalize version comparison (remove v prefix)
            latest_norm = latest.lstrip('v')
            current_norm = current_version.lstrip('v')

            if latest_norm != current_norm:
                self.warnings.append(
                    f"  {app_name}: Chart '{name}' update available: {current_version} -> {latest}"
                )

    def check_kustomize_build(self, app_dir: Path, app_name: str) -> None:
        """Test if kustomize can successfully build the manifests."""
        code, _, stderr = self.run_command(
            ["kustomize", "build", "--enable-helm", "--load-restrictor=LoadRestrictionsNone", str(app_dir)],
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
        kustomization_data = self.load_yaml(kustomization_file)
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

            if not self.check_helm_chart_fields(chart, idx, app_name,
                                                kustomization_file, kustomization_data):
                continue

            version = chart.get("version")
            values_file_path = chart.get("valuesFile")

            # Check for updates
            if version:
                self.check_version_update(chart, app_name)

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
        help="Automatically fix issues (add missing fields, fetch versions)"
    )
    parser.add_argument(
        "--update",
        action="store_true",
        help="Check for helm chart version updates (fetches latest versions from repositories)"
    )
    parser.add_argument(
        "files",
        nargs="*",
        help="Changed files passed by pre-commit (limits checks to affected apps)"
    )
    args = parser.parse_args()

    repo_root = get_git_root()
    checker = Checker(auto_fix=args.fix, update_versions=args.update)
    return checker.run_checks(repo_root, files=args.files)


if __name__ == "__main__":
    sys.exit(main())
