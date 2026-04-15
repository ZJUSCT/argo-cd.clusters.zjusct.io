#!/usr/bin/env python3
"""Check for available updates to Helm charts and container images.

This is a read-only notification tool — it never modifies repository files.
"""

import argparse
import re
import sys
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Dict, List, Optional, Tuple

# Allow importing sibling module without package setup
sys.path.insert(0, str(Path(__file__).resolve().parent))
from version_utils import (
    HARBOR_PREFIX,
    VersionCache,
    get_latest_github_release_version,
    get_latest_helm_version_http,
    get_latest_helm_version_oci,
    get_latest_image_tag,
    load_yaml,
    parse_image_ref,
    parse_semver,
    sort_semver_tags,
    strip_harbor_prefix,
)

# ---------------------------------------------------------------------------
# Directories to scan / skip
# ---------------------------------------------------------------------------

SCAN_DIRS = ("production", "dev")
SKIP_DIRS = {"disabled", "tmp", "packer", ".devcontainer", "charts"}

# ---------------------------------------------------------------------------
# Result types
# ---------------------------------------------------------------------------

@dataclass
class HelmItem:
    """A Helm chart to check."""
    app_name: str
    chart_name: str
    repo: str
    current_version: str
    is_oci: bool


@dataclass
class ImageItem:
    """A container image to check."""
    app_name: str
    image_ref: str       # original ref as found in file
    registry: str
    repository: str
    current_tag: str
    source_file: str


@dataclass
class GitHubReleaseItem:
    """A raw resource pinned to a GitHub release."""
    app_name: str
    owner_repo: str      # e.g. "tektoncd/operator"
    current_tag: str     # e.g. "v0.79.0"
    source_file: str


@dataclass
class Update:
    """An available update."""
    app_name: str
    resource_name: str
    current: str
    latest: str
    source_file: str = ""


@dataclass
class CheckError:
    app_name: str
    resource_name: str
    source_file: str = ""
    message: str = ""


@dataclass
class CategoryResult:
    """Results for one category (helm / values-image / resource-image)."""
    title: str
    total: int = 0
    updates: List[Update] = field(default_factory=list)
    errors: List[CheckError] = field(default_factory=list)
    up_to_date: List[Tuple[str, str, str]] = field(default_factory=list)  # (app, name, version)

    @property
    def update_count(self) -> int:
        return len(self.updates)

    @property
    def error_count(self) -> int:
        return len(self.errors)


# ---------------------------------------------------------------------------
# Scanning helpers
# ---------------------------------------------------------------------------

def _app_dirs(repo_root: Path) -> List[Path]:
    """Return application directories under SCAN_DIRS."""
    dirs: List[Path] = []
    for env in SCAN_DIRS:
        env_path = repo_root / env
        if not env_path.is_dir():
            continue
        for d in sorted(env_path.iterdir()):
            if d.is_dir() and (d / "kustomization.yaml").exists():
                dirs.append(d)
    return dirs


def _skip_path(p: Path) -> bool:
    """True if *p* is inside a skipped directory."""
    for part in p.parts:
        if part in SKIP_DIRS:
            return True
    return False


# ---------------------------------------------------------------------------
# Helm chart scanner
# ---------------------------------------------------------------------------

def scan_helm_charts(repo_root: Path) -> List[HelmItem]:
    items: List[HelmItem] = []
    for app_dir in _app_dirs(repo_root):
        app_name = str(app_dir.relative_to(repo_root))
        data = load_yaml(app_dir / "kustomization.yaml")
        if not data:
            continue
        for chart in data.get("helmCharts", []):
            name = chart.get("name", "")
            repo = chart.get("repo", "")
            version = chart.get("version", "")
            if not name or not repo or not version:
                continue  # skip local charts or incomplete entries
            is_oci = repo.startswith("oci://")
            items.append(HelmItem(
                app_name=app_name,
                chart_name=name,
                repo=repo,
                current_version=version,
                is_oci=is_oci,
            ))
    return items


# ---------------------------------------------------------------------------
# GitHub release resource scanner
# ---------------------------------------------------------------------------

_GITHUB_RELEASE_RE = re.compile(
    r"https://github\.com/([^/\s]+/[^/\s]+)/releases/download/([^/\s]+)/[^/\s]+"
)


def scan_github_release_resources(repo_root: Path) -> List[GitHubReleaseItem]:
    items: List[GitHubReleaseItem] = []
    for app_dir in _app_dirs(repo_root):
        app_name = str(app_dir.relative_to(repo_root))
        kustomization = app_dir / "kustomization.yaml"
        data = load_yaml(kustomization)
        if not data:
            continue
        seen: set = set()
        for resource in data.get("resources", []):
            if not isinstance(resource, str):
                continue
            m = _GITHUB_RELEASE_RE.match(resource)
            if not m:
                continue
            owner_repo, tag = m.group(1), m.group(2)
            if owner_repo in seen:
                continue
            seen.add(owner_repo)
            items.append(GitHubReleaseItem(
                app_name=app_name,
                owner_repo=owner_repo,
                current_tag=tag,
                source_file=str(kustomization.relative_to(repo_root)),
            ))
    return items


# ---------------------------------------------------------------------------
# Values file image scanner
# ---------------------------------------------------------------------------

def _walk_values_node(node, refs: List[Tuple[str, Optional[str]]]) -> None:
    """Recursively walk a YAML tree extracting image references."""
    if not isinstance(node, dict):
        return

    # Pattern 1: object-style — sibling `repository` + `tag`
    repo_val = node.get("repository")
    if isinstance(repo_val, str) and repo_val:
        tag_val = node.get("tag")
        if isinstance(tag_val, str) and tag_val and tag_val != "latest":
            refs.append((repo_val, tag_val))

    # Pattern 2: inline `image:` string with colon (tag separator)
    img_val = node.get("image")
    if isinstance(img_val, str) and ":" in img_val:
        parsed = parse_image_ref(img_val)
        if parsed:
            registry, repository, tag = parsed
            if tag and tag != "latest":
                refs.append((f"{registry}/{repository}", tag))

    # Recurse
    for value in node.values():
        if isinstance(value, dict):
            _walk_values_node(value, refs)
        elif isinstance(value, list):
            for item in value:
                if isinstance(item, dict):
                    _walk_values_node(item, refs)


def scan_values_images(repo_root: Path) -> List[ImageItem]:
    items: List[ImageItem] = []
    for app_dir in _app_dirs(repo_root):
        app_name = str(app_dir.relative_to(repo_root))
        values_dir = app_dir / "values"
        if not values_dir.is_dir():
            continue
        for vf in sorted(values_dir.glob("*.yaml")):
            data = load_yaml(vf)
            if not data:
                continue
            refs: List[Tuple[str, Optional[str]]] = []
            _walk_values_node(data, refs)
            # Deduplicate within this file
            seen: set = set()
            for repo_str, tag in refs:
                parsed = parse_image_ref(f"{repo_str}:{tag}")
                if not parsed:
                    continue
                registry, repository, _ = parsed
                key = (registry, repository)
                if key in seen:
                    continue
                seen.add(key)
                items.append(ImageItem(
                    app_name=app_name,
                    image_ref=f"{registry}/{repository}:{tag}",
                    registry=registry,
                    repository=repository,
                    current_tag=tag,
                    source_file=str(vf.relative_to(repo_root)),
                ))
    return items


# ---------------------------------------------------------------------------
# Resource file image scanner
# ---------------------------------------------------------------------------

_IMAGE_RE = re.compile(r"^\s*-?\s*image:\s*['\"]?([^\s'\"]+)")


def _walk_resource_node(node, refs: List[str]) -> None:
    """Recursively walk a YAML tree looking for `image:` string values."""
    if isinstance(node, dict):
        img = node.get("image")
        if isinstance(img, str) and ":" in img and not img.startswith("#"):
            refs.append(img.strip().strip('"').strip("'"))
        for value in node.values():
            if isinstance(value, dict):
                _walk_resource_node(value, refs)
            elif isinstance(value, list):
                for item in value:
                    if isinstance(item, dict):
                        _walk_resource_node(item, refs)


def scan_resource_images(repo_root: Path) -> List[ImageItem]:
    items: List[ImageItem] = []
    for app_dir in _app_dirs(repo_root):
        app_name = str(app_dir.relative_to(repo_root))
        res_dir = app_dir / "resources"
        if not res_dir.is_dir():
            continue
        for rf in sorted(res_dir.glob("*.yaml")):
            # Load all documents (multi-doc YAML)
            try:
                import yaml
                with open(rf, "r") as f:
                    docs = list(yaml.safe_load_all(f))
            except Exception:
                continue

            refs: List[str] = []
            for doc in docs:
                if isinstance(doc, dict):
                    _walk_resource_node(doc, refs)

            seen: set = set()
            rel = str(rf.relative_to(repo_root))
            for raw_ref in refs:
                cleaned = strip_harbor_prefix(raw_ref)
                parsed = parse_image_ref(cleaned)
                if not parsed:
                    continue
                registry, repository, tag = parsed
                if not tag or tag == "latest":
                    continue
                if not parse_semver(tag):
                    continue  # skip non-semver like commit SHAs
                key = (registry, repository)
                if key in seen:
                    continue
                seen.add(key)
                items.append(ImageItem(
                    app_name=app_name,
                    image_ref=f"{registry}/{repository}:{tag}",
                    registry=registry,
                    repository=repository,
                    current_tag=tag,
                    source_file=rel,
                ))
    return items


# ---------------------------------------------------------------------------
# Query phase
# ---------------------------------------------------------------------------

def _query_helm(item: HelmItem, cache: VersionCache) -> Tuple[Optional[str], Optional[str]]:
    """Return (latest_version, error_message)."""
    try:
        if item.is_oci:
            latest, error = get_latest_helm_version_oci(item.chart_name, item.repo, cache)
        else:
            latest, error = get_latest_helm_version_http(item.chart_name, item.repo, cache)
        if error:
            return None, error
        if latest is None:
            return None, "failed to fetch latest version"
        # Normalize for comparison
        cur = item.current_version.lstrip("v")
        lat = latest.lstrip("v")
        if cur == lat:
            return item.current_version, None
        return latest, None
    except Exception as e:
        return None, str(e)


def _query_github(item: GitHubReleaseItem, cache: VersionCache) -> Tuple[Optional[str], Optional[str]]:
    """Return (latest_tag, error_message)."""
    try:
        latest, err = get_latest_github_release_version(item.owner_repo, cache)
        if err:
            return None, err
        if latest is None:
            return None, "no stable release found"
        cur = item.current_tag.lstrip("v")
        lat = latest.lstrip("v")
        if cur == lat:
            return item.current_tag, None
        return latest, None
    except Exception as e:
        return None, str(e)


def _query_image(item: ImageItem, cache: VersionCache) -> Tuple[Optional[str], Optional[str]]:
    """Return (latest_tag, error_message)."""
    try:
        latest, err = get_latest_image_tag(item.registry, item.repository, cache)
        if err:
            return None, err
        if latest is None:
            return None, "no semver tags found"
        # Normalize for comparison
        cur = item.current_tag.lstrip("v")
        lat = latest.lstrip("v")
        if cur == lat:
            return item.current_tag, None
        return latest, None
    except Exception as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# Report formatting
# ---------------------------------------------------------------------------

def _print_section(result: CategoryResult) -> None:
    print(f"\n=== {result.title} ===")
    if not result.updates and not result.up_to_date and not result.errors:
        print("  (none found)")
        return

    # Updates first
    for u in result.updates:
        src = f"  [{u.source_file}]" if u.source_file else ""
        print(f"  {u.app_name:40s} {u.resource_name:45s} {u.current:15s} -> {u.latest}{src}")

    # Up to date (compact)
    for app, name, ver in result.up_to_date:
        print(f"  {app:40s} {name:45s} {ver:15s} OK")

    # Errors
    for e in result.errors:
        src = f" [{e.source_file}]" if e.source_file else ""
        print(f"  ERROR: {e.app_name:40s} {e.resource_name:30s}{src} {e.message}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main() -> int:
    parser = argparse.ArgumentParser(
        description="Check for available updates to Helm charts, GitHub releases, and container images."
    )
    scope = parser.add_mutually_exclusive_group()
    scope.add_argument("--helm", action="store_true", help="Check Helm chart versions only")
    scope.add_argument("--github", action="store_true", help="Check GitHub release resource versions only")
    scope.add_argument("--images", action="store_true", help="Check container image versions only")
    parser.add_argument("--workers", type=int, default=8,
                        help="Concurrent registry queries (default: 8)")
    args = parser.parse_args()

    # Default run (no flags): helm + github. Images remain opt-in via --images.
    check_helm = args.helm or (not args.github and not args.images)
    check_github = args.github or (not args.helm and not args.images)
    check_images = args.images

    repo_root = Path(__file__).resolve().parent.parent
    cache = VersionCache()

    # --- Phase 1: Scan (fast, no network) ---
    helm_items: List[HelmItem] = []
    github_items: List[GitHubReleaseItem] = []
    image_items: List[ImageItem] = []

    if check_helm:
        helm_items = scan_helm_charts(repo_root)
    if check_github:
        github_items = scan_github_release_resources(repo_root)
    if check_images:
        image_items = scan_values_images(repo_root) + scan_resource_images(repo_root)

    total_items = len(helm_items) + len(github_items) + len(image_items)
    if total_items == 0:
        print("No versioned resources found.")
        return 0

    parts = []
    if check_helm:
        parts.append(f"{len(helm_items)} Helm charts")
    if check_github:
        parts.append(f"{len(github_items)} GitHub release resources")
    if check_images:
        parts.append(f"{len(image_items)} images")
    print(f"Scanning {', '.join(parts)}...\n")

    # --- Phase 2: Query (network, parallel) ---
    helm_result = CategoryResult(title="Helm Chart Versions")
    github_result = CategoryResult(title="GitHub Release Resources")
    values_result = CategoryResult(title="Container Images (values files)")
    resource_result = CategoryResult(title="Container Images (resource files)")

    def _print_helm_update(u: Update) -> None:
        print(f"  UPDATE: {u.app_name:40s} {u.resource_name:45s} {u.current:15s} -> {u.latest}", flush=True)

    def _print_helm_ok(app: str, name: str, ver: str) -> None:
        print(f"  OK:     {app:40s} {name:45s} {ver:15s}", flush=True)

    def _print_helm_error(e: CheckError) -> None:
        print(f"  ERROR:  {e.app_name:40s} {e.resource_name:30s} {e.message}", flush=True)

    def _print_image_update(u: Update) -> None:
        print(f"  UPDATE: {u.app_name:40s} {u.resource_name:45s} {u.current:15s} -> {u.latest}  [{u.source_file}]", flush=True)

    def _print_image_ok(app: str, name: str, ver: str) -> None:
        print(f"  OK:     {app:40s} {name:45s} {ver:15s}", flush=True)

    def _print_image_error(e: CheckError) -> None:
        print(f"  ERROR:  {e.app_name:40s} {e.resource_name:30s} [{e.source_file}] {e.message}", flush=True)

    def _print_github_update(u: Update) -> None:
        print(f"  UPDATE: {u.app_name:40s} {u.resource_name:45s} {u.current:15s} -> {u.latest}  [{u.source_file}]", flush=True)

    def _print_github_ok(app: str, name: str, ver: str) -> None:
        print(f"  OK:     {app:40s} {name:45s} {ver:15s}", flush=True)

    def _print_github_error(e: CheckError) -> None:
        print(f"  ERROR:  {e.app_name:40s} {e.resource_name:30s} [{e.source_file}] {e.message}", flush=True)

    # Submit all queries
    futures: dict = {}

    with ThreadPoolExecutor(max_workers=args.workers) as pool:
        for item in helm_items:
            f = pool.submit(_query_helm, item, cache)
            futures[f] = ("helm", item)

        for item in github_items:
            f = pool.submit(_query_github, item, cache)
            futures[f] = ("github", item)

        # Track which image items come from values vs resources
        values_sources = {str(i.source_file) for i in scan_values_images(repo_root)} if check_images else set()

        for item in image_items:
            f = pool.submit(_query_image, item, cache)
            futures[f] = ("image", item)

        for future in as_completed(futures):
            category, item = futures[future]
            latest, error = future.result()

            if category == "helm":
                item: HelmItem  # type: ignore
                helm_result.total += 1
                if error:
                    err_obj = CheckError(
                        app_name=item.app_name,
                        resource_name=item.chart_name,
                        message=error,
                    )
                    helm_result.errors.append(err_obj)
                    _print_helm_error(err_obj)
                elif latest and latest.lstrip("v") != item.current_version.lstrip("v"):
                    upd = Update(
                        app_name=item.app_name,
                        resource_name=item.chart_name,
                        current=item.current_version,
                        latest=latest,
                    )
                    helm_result.updates.append(upd)
                    _print_helm_update(upd)
                else:
                    helm_result.up_to_date.append((item.app_name, item.chart_name, item.current_version))
                    _print_helm_ok(item.app_name, item.chart_name, item.current_version)

            elif category == "github":
                item: GitHubReleaseItem  # type: ignore
                github_result.total += 1
                if error:
                    err_obj = CheckError(
                        app_name=item.app_name,
                        resource_name=item.owner_repo,
                        source_file=item.source_file,
                        message=error,
                    )
                    github_result.errors.append(err_obj)
                    _print_github_error(err_obj)
                elif latest and latest.lstrip("v") != item.current_tag.lstrip("v"):
                    upd = Update(
                        app_name=item.app_name,
                        resource_name=item.owner_repo,
                        current=item.current_tag,
                        latest=latest,
                        source_file=item.source_file,
                    )
                    github_result.updates.append(upd)
                    _print_github_update(upd)
                else:
                    github_result.up_to_date.append((item.app_name, item.owner_repo, item.current_tag))
                    _print_github_ok(item.app_name, item.owner_repo, item.current_tag)

            elif category == "image":
                item: ImageItem  # type: ignore
                target = values_result if item.source_file in values_sources else resource_result
                target.total += 1
                if error:
                    err_obj = CheckError(
                        app_name=item.app_name,
                        resource_name=item.image_ref,
                        source_file=item.source_file,
                        message=error,
                    )
                    target.errors.append(err_obj)
                    _print_image_error(err_obj)
                elif latest and latest.lstrip("v") != item.current_tag.lstrip("v"):
                    upd = Update(
                        app_name=item.app_name,
                        resource_name=item.image_ref,
                        current=item.current_tag,
                        latest=latest,
                        source_file=item.source_file,
                    )
                    target.updates.append(upd)
                    _print_image_update(upd)
                else:
                    target.up_to_date.append((item.app_name, item.image_ref, item.current_tag))
                    _print_image_ok(item.app_name, item.image_ref, item.current_tag)

    # Summary
    all_results = []
    if check_helm:
        all_results.append(helm_result)
    if check_github:
        all_results.append(github_result)
    if check_images:
        all_results.extend([values_result, resource_result])

    total_checked = sum(r.total for r in all_results)
    total_updates = sum(r.update_count for r in all_results)
    total_errors = sum(r.error_count for r in all_results)

    print(f"\n=== Summary ===")
    print(f"  Total:   {total_checked} checked, {total_updates} updates available")
    if total_errors:
        print(f"  Errors:  {total_errors} (failed to query registry)")
    if total_updates == 0 and total_errors == 0:
        print("  All up to date.")

    return 0  # always exit 0 — notification only


if __name__ == "__main__":
    sys.exit(main())
