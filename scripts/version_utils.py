"""Shared utilities for Helm chart and container image version lookups."""

import json
import re
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import yaml
except ImportError:
    raise SystemExit("Error: PyYAML not installed. Install with: pip install pyyaml")

_YAML_LOADER = yaml.CSafeLoader if hasattr(yaml, "CSafeLoader") else yaml.SafeLoader

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

HARBOR_PREFIX = "harbor.clusters.zjusct.io/"

_SCAN_RE = re.compile(r"^v?\d+\.\d+\.\d+")

# Patterns that indicate genuinely unstable/prerelease versions — these are
# filtered out.  Everything else (including "-stable", bare versions, and
# unrecognised suffixes) passes through so the user can decide.
_UNSTABLE_PATTERNS = [
    r"-alpha",
    r"-beta",
    r"-rc",
    r"-nightly",
    r"-dev",
    r"-preview",
    r"-pre",
    r"-snapshot",
    r"-canary",
    r"-unstable",
    r"-experimental",
    r"-weekly",
]

_MIN_AGE_DAYS = 7
_MAX_OCI_CANDIDATES = 20
_MAX_TAG_PAGES = 10
_TAG_PAGE_SIZE = 1000


# ---------------------------------------------------------------------------
# Age filter
# ---------------------------------------------------------------------------

def _is_old_enough(timestamp_str: Optional[str]) -> bool:
    """Return True if *timestamp_str* is at least *_MIN_AGE_DAYS* old."""
    if not timestamp_str:
        return False
    try:
        created = datetime.fromisoformat(timestamp_str.replace("Z", "+00:00"))
        return datetime.now(timezone.utc) - created >= timedelta(days=_MIN_AGE_DAYS)
    except Exception:
        return False


# ---------------------------------------------------------------------------
# Version cache
# ---------------------------------------------------------------------------

class VersionCache:
    """Simple dict-based cache keyed by (type, identifier).

    Supports per-key locking so that expensive operations (e.g. downloading a
    large Helm index.yaml) are only performed once even when multiple threads
    request the same key concurrently.
    """

    def __init__(self) -> None:
        self._data: Dict[Tuple[str, str], Any] = {}
        self._lock = threading.Lock()
        self._key_locks: Dict[Tuple[str, str], threading.Lock] = {}

    def _key_lock(self, key: Tuple[str, str]) -> threading.Lock:
        with self._lock:
            if key not in self._key_locks:
                self._key_locks[key] = threading.Lock()
            return self._key_locks[key]

    def get(self, key: Tuple[str, str]) -> Any:
        return self._data.get(key)

    def put(self, key: Tuple[str, str], value: Any) -> None:
        self._data[key] = value

    def get_or_compute(self, key: Tuple[str, str], compute: Callable[[], Any]) -> Any:
        """Return cached value for *key* or run *compute* to produce it.

        *compute* is guaranteed to run at most once per key, even across
        multiple threads.
        """
        value = self.get(key)
        if value is not None:
            return value

        lock = self._key_lock(key)
        with lock:
            value = self.get(key)
            if value is not None:
                return value
            value = compute()
            self.put(key, value)
            return value


# ---------------------------------------------------------------------------
# YAML helpers
# ---------------------------------------------------------------------------

def load_yaml(file_path: Path) -> Optional[dict]:
    """Load and parse a YAML file."""
    try:
        with open(file_path, "r") as f:
            return yaml.load(f, Loader=_YAML_LOADER)
    except FileNotFoundError:
        return None
    except yaml.YAMLError:
        return None


def is_prerelease(version: str) -> bool:
    """True if *version* is an unstable pre-release (alpha, beta, rc, nightly, etc.).

    Only matches known unstable patterns.  ``-stable`` and other non-standard
    suffixes are NOT treated as prerelease — they pass through for the user to
    review manually.
    """
    m = re.match(r"^v?\d+\.\d+\.\d+", version)
    if not m:
        return True  # doesn't look like a version at all
    suffix = version[m.end():].lower()
    if not suffix:
        return False
    for pattern in _UNSTABLE_PATTERNS:
        if re.match(pattern, suffix):
            return True
    return False


# ---------------------------------------------------------------------------
# Semver helpers
# ---------------------------------------------------------------------------

def parse_semver(tag: str) -> Optional[Tuple[int, ...]]:
    """Extract numeric parts of a semver tag.

    Returns None for non-semver strings (e.g. ``master``, ``3fb70258``).
    """
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", tag)
    if not m:
        return None
    return (int(m.group(1)), int(m.group(2)), int(m.group(3)))


def _parse_version_for_sort(version: str) -> Optional[Tuple[int, ...]]:
    """Parse a version into a sortable tuple.

    Extracts the semver triplet plus any trailing numbers from the suffix
    (e.g. ``1.83.14-stable.patch.3`` → ``(1, 83, 14, 3)``).

    Returns *None* for unparseable strings.
    """
    m = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", version)
    if not m:
        return None
    base = (int(m.group(1)), int(m.group(2)), int(m.group(3)))
    extra = tuple(int(n) for n in re.findall(r"\d+", version[m.end():]))
    return base + extra


def sort_semver_tags(tags: List[str]) -> List[str]:
    """Return *tags* sorted descending (latest first).

    Sorts by semver triplet and any trailing numbers extracted from the suffix.
    Falls back to string comparison when numeric parts are identical.
    """
    def _key(t: str):
        parsed = _parse_version_for_sort(t)
        if parsed is None:
            return ((), t)
        return (parsed, t)

    tagged = [(t, _key(t)) for t in tags if parse_semver(t) is not None]
    tagged.sort(key=lambda x: x[1], reverse=True)
    return [t for t, _ in tagged]


def has_non_semver_suffix(version: str) -> bool:
    """True if *version* has a suffix that is neither bare semver nor a known
    unstable prerelease pattern.

    Used to warn the user about non-standard version names that require
    manual review.
    """
    m = re.match(r"^v?\d+\.\d+\.\d+", version)
    if not m:
        return True
    suffix = version[m.end():]
    return bool(suffix)


@dataclass
class VersionCandidates:
    """Result of an upstream version query.

    *candidates* is ordered newest-first and contains at most 5 entries.
    *current_date* is the creation date of the version currently deployed
    (``None`` when unavailable).
    """
    candidates: List[Tuple[str, str]] = field(default_factory=list)
    current_date: Optional[str] = None
    error: Optional[str] = None


# ---------------------------------------------------------------------------
# Image reference parsing
# ---------------------------------------------------------------------------

def strip_harbor_prefix(image_ref: str) -> str:
    """Remove the local Harbor pull-through-cache prefix from an image ref."""
    if image_ref.startswith(HARBOR_PREFIX):
        return image_ref[len(HARBOR_PREFIX):]
    return image_ref


def parse_image_ref(ref: str) -> Optional[Tuple[str, str, Optional[str]]]:
    """Parse an image reference into *(registry, repository, tag)*.

    Handles:
    - ``docker.io/rook/ceph:v1.19.1``
    - ``busybox:1.37.0`` → ``("docker.io", "library/busybox", "1.37.0")``
    - ``ghcr.io/foo/bar@sha256:...`` → tag is ``None``
    - Non-parseable strings → ``None``
    """
    ref = ref.strip().strip('"').strip("'")
    if not ref:
        return None

    # Split digest if present
    digest: Optional[str] = None
    if "@sha256:" in ref:
        ref, digest = ref.split("@sha256:", 1)
        digest = f"sha256:{digest}"

    # Split tag if present
    tag: Optional[str] = None
    if ":" in ref:
        parts = ref.rsplit(":", 1)
        if "/" not in parts[-1]:
            # No slash in the last segment — it's a tag, not registry:port
            ref, tag = parts

    if not tag and not digest:
        return None

    # Determine registry vs repository
    if "/" in ref:
        first_segment = ref.split("/", 1)[0]
        if "." in first_segment or ":" in first_segment:
            # Has registry: registry.example.com/repo or localhost:5000/repo
            registry = first_segment
            repository = ref[len(first_segment) + 1:]
            if not repository:
                return None
        else:
            # No registry indicator: docker.io
            registry = "docker.io"
            repository = ref
            # Implicit Docker Hub library path for single-segment names
            if "/" not in repository:
                repository = f"library/{repository}"
    else:
        registry = "docker.io"
        repository = f"library/{ref}"

    return (registry, repository, tag)


# ---------------------------------------------------------------------------
# Generic OCI registry auth
# ---------------------------------------------------------------------------

def _get_oci_auth_token(registry: str, repository: str) -> Tuple[Optional[str], Optional[str]]:
    """Obtain a Bearer token for an OCI registry by following the WWW-Authenticate challenge.

    Returns *(token, error_message)*.
    """
    tags_url = f"https://{registry}/v2/{repository}/tags/list"
    req = urllib.request.Request(tags_url)
    req.add_header("Accept", "application/json")
    req.add_header("User-Agent", _helm_user_agent())

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            # Registry allows anonymous access.
            return None, None
    except urllib.error.HTTPError as e:
        if e.code != 401:
            return None, f"HTTP {e.code} {e.reason}"
        www_auth = e.headers.get("WWW-Authenticate", "")
        if not www_auth.startswith("Bearer "):
            return None, f"unsupported auth scheme: {www_auth}"

        params = {}
        for match in re.finditer(r'(\w+)="([^"]+)"', www_auth):
            params[match.group(1)] = match.group(2)

        realm = params.get("realm")
        if not realm:
            return None, "missing realm in WWW-Authenticate header"

        query = {}
        if "service" in params:
            query["service"] = params["service"]
        if "scope" in params:
            query["scope"] = params["scope"]

        token_url = realm
        if query:
            token_url += "?" + urllib.parse.urlencode(query)

        try:
            req = urllib.request.Request(token_url)
            req.add_header("User-Agent", _helm_user_agent())
            with urllib.request.urlopen(req, timeout=20) as resp:
                data = json.loads(resp.read())
                token = data.get("token") or data.get("access_token")
                if not token:
                    return None, "empty token response from auth server"
                return token, None
        except urllib.error.HTTPError as ae:
            return None, f"auth HTTP {ae.code} {ae.reason}"
        except Exception as ae:
            return None, f"auth error: {ae}"
    except Exception as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# OCI helpers
# ---------------------------------------------------------------------------

def _helm_user_agent() -> str:
    return "helm-chart-validator/1.0"


def _fetch_oci_tags(registry: str, repository: str,
                    token: Optional[str]) -> Tuple[List[str], Optional[str]]:
    """Fetch all tags from an OCI registry, following pagination.

    Returns *(tags_list, error_message)*.
    """
    all_tags: List[str] = []
    url = f"https://{registry}/v2/{repository}/tags/list?n={_TAG_PAGE_SIZE}"
    headers = {
        "Accept": "application/json",
        "User-Agent": _helm_user_agent(),
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    for _ in range(_MAX_TAG_PAGES):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())
                tags = data.get("tags") or []
                all_tags.extend(tags)

                link_hdr = resp.headers.get("Link", "")
                if 'rel="next"' not in link_hdr:
                    break

                for part in link_hdr.split(","):
                    if 'rel="next"' in part:
                        match = re.search(r"<(.+?)>", part)
                        if match:
                            raw_next = match.group(1)
                            url = urllib.parse.urljoin(f"https://{registry}", raw_next)
                        else:
                            return all_tags, None
                        break
                else:
                    break
        except urllib.error.HTTPError as e:
            return all_tags, f"HTTP {e.code} {e.reason}"
        except Exception as e:
            return all_tags, str(e)

    return all_tags, None


def _get_oci_manifest_created(registry: str, repository: str,
                              tag: str, token: Optional[str]) -> Tuple[Optional[str], Optional[str]]:
    """Return the created timestamp for an OCI manifest (or None + error)."""
    url = f"https://{registry}/v2/{repository}/manifests/{tag}"
    headers = {
        "Accept": (
            "application/vnd.oci.image.manifest.v1+json,"
            "application/vnd.docker.distribution.manifest.v2+json"
        ),
        "User-Agent": _helm_user_agent(),
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    try:
        req = urllib.request.Request(url, headers=headers)
        with urllib.request.urlopen(req, timeout=15) as resp:
            manifest = json.loads(resp.read())
            created = manifest.get("annotations", {}).get("org.opencontainers.image.created")
            if created:
                return created, None

            # Fallback to config blob
            config = manifest.get("config", {})
            digest = config.get("digest")
            if digest:
                blob_url = f"https://{registry}/v2/{repository}/blobs/{digest}"
                req = urllib.request.Request(blob_url, headers=headers)
                with urllib.request.urlopen(req, timeout=15) as bresp:
                    config_data = json.loads(bresp.read())
                    created = config_data.get("created")
                    if created:
                        return created, None
            return None, "no created timestamp in manifest"
    except urllib.error.HTTPError as e:
        return None, f"HTTP {e.code} {e.reason}"
    except Exception as e:
        return None, str(e)


# ---------------------------------------------------------------------------
# Helm chart version lookups (HTTP and OCI)
# ---------------------------------------------------------------------------

def get_latest_helm_version_http(chart_name: str, repo_url: str,
                                 current_version: str,
                                 cache: VersionCache) -> VersionCandidates:
    """Query an HTTP Helm repo ``index.yaml`` for the newest chart versions
    (at least 7 days old, excluding unstable prereleases).

    Returns up to 5 candidates, newest first.
    """
    if not repo_url.endswith("/"):
        repo_url += "/"

    # Cache parsed index.yaml per repo URL.
    index_key = ("helm_index", repo_url)

    def _fetch_index() -> Optional[dict]:
        index_url = repo_url + "index.yaml"
        try:
            req = urllib.request.Request(index_url)
            req.add_header("User-Agent", _helm_user_agent())
            with urllib.request.urlopen(req, timeout=60) as resp:
                return yaml.load(resp.read(), Loader=_YAML_LOADER)
        except Exception:
            return None

    index_data = cache.get_or_compute(index_key, _fetch_index)
    if index_data is None:
        return VersionCandidates(error="failed to fetch or parse index.yaml")

    entries = index_data.get("entries", {})
    chart_entries = entries.get(chart_name, [])
    if not chart_entries:
        return VersionCandidates(error="chart not found in index")

    # Collect all qualifying versions with dates; deduplicate by version.
    seen: set = set()
    collected: List[Tuple[str, str]] = []
    current_date: Optional[str] = None

    for entry in chart_entries:
        ver = entry.get("version", "")
        created = entry.get("created", "")
        if not ver:
            continue
        if is_prerelease(ver):
            continue
        if not _is_old_enough(created):
            continue
        if ver in seen:
            continue
        seen.add(ver)

        # Track date for current version
        if ver == current_version and not current_date:
            current_date = created or None

        collected.append((ver, created or ""))

    if not collected:
        return VersionCandidates(
            current_date=current_date,
            error="no stable version at least 7 days old",
        )

    # Sort by version descending, then by date descending as tiebreaker
    def _sort_key(item: Tuple[str, str]) -> Tuple[Tuple[int, ...], str]:
        parsed = _parse_version_for_sort(item[0])
        return (parsed or (0, 0, 0), item[1])

    collected.sort(key=_sort_key, reverse=True)

    return VersionCandidates(
        candidates=collected[:5],
        current_date=current_date,
    )


def get_latest_helm_version_oci(chart_name: str, repo_url: str,
                                current_version: str,
                                cache: VersionCache) -> VersionCandidates:
    """Query an OCI registry for the newest Helm chart versions (at least 7 days
    old, excluding unstable prereleases).

    Returns up to 5 candidates, newest first.  Dates are obtained from OCI
    manifests (one request per tag).
    """
    try:
        parsed = urllib.parse.urlparse(repo_url)
        registry = parsed.netloc
        path_part = parsed.path.strip("/")
        image = f"{path_part}/{chart_name}" if path_part else chart_name

        if "docker.io" in registry:
            api_registry = "registry-1.docker.io"
        else:
            api_registry = registry

        docker_image = image
        if api_registry == "registry-1.docker.io" and "/" not in image:
            docker_image = f"library/{image}"

        token, auth_err = _get_oci_auth_token(api_registry, docker_image)
        if auth_err:
            return VersionCandidates(error=auth_err)

        # Cache tags list per repo
        tags_key = ("oci_tags", f"{api_registry}/{docker_image}")
        tags: Optional[List[str]] = cache.get(tags_key)

        if tags is None:
            raw_tags, tags_err = _fetch_oci_tags(api_registry, docker_image, token)
            if tags_err:
                return VersionCandidates(error=tags_err)
            tags = sort_semver_tags(
                [t for t in raw_tags if _SCAN_RE.match(t) and not is_prerelease(t)]
            )
            cache.put(tags_key, tags)

        if not tags:
            return VersionCandidates(error="no stable semver tags found")

        # Fetch manifests for top candidates to get dates.
        collected: List[Tuple[str, str]] = []
        current_date: Optional[str] = None

        for tag in tags[:_MAX_OCI_CANDIDATES]:
            created, created_err = _get_oci_manifest_created(
                api_registry, docker_image, tag, token
            )
            if created_err:
                continue
            if not _is_old_enough(created):
                continue
            if tag == current_version and not current_date:
                current_date = created
            collected.append((tag, created))
            if len(collected) >= 5:
                break

        if not collected:
            return VersionCandidates(
                current_date=current_date,
                error="no stable OCI chart version at least 7 days old",
            )

        return VersionCandidates(
            candidates=collected,
            current_date=current_date,
        )

    except Exception as e:
        return VersionCandidates(error=str(e))


# ---------------------------------------------------------------------------
# GitHub release version lookup
# ---------------------------------------------------------------------------

def get_latest_github_release_version(owner_repo: str,
                                       current_tag: str,
                                       cache: VersionCache) -> VersionCandidates:
    """Query the GitHub Releases API for the newest stable releases (at least
    7 days old, excluding prereleases and drafts).

    Returns up to 5 candidates, newest first.

    *owner_repo* should be ``"owner/repo"`` (e.g. ``"tektoncd/operator"``).
    """
    url = f"https://api.github.com/repos/{owner_repo}/releases?per_page=25"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github+json")
    req.add_header("User-Agent", _helm_user_agent())
    req.add_header("X-GitHub-Api-Version", "2022-11-28")

    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            releases = json.loads(resp.read())
    except urllib.error.HTTPError as e:
        return VersionCandidates(error=f"HTTP {e.code} {e.reason}")
    except Exception as e:
        return VersionCandidates(error=str(e))

    current_date: Optional[str] = None
    collected: List[Tuple[str, str]] = []
    for r in releases:
        if r.get("prerelease") or r.get("draft"):
            continue
        tag_name = r.get("tag_name", "")
        published = r.get("published_at", "")
        if not parse_semver(tag_name):
            continue
        if not _is_old_enough(published):
            continue
        # uses GitHub's prerelease flag, not our blocklist, so also check
        if is_prerelease(tag_name):
            continue
        if tag_name == current_tag:
            current_date = published or current_date
        collected.append((tag_name, published or ""))

    if not collected:
        return VersionCandidates(
            current_date=current_date,
            error="no stable release at least 7 days old",
        )

    def _sort_key(item: Tuple[str, str]) -> Tuple[Tuple[int, ...], str]:
        parsed = _parse_version_for_sort(item[0])
        return (parsed or (0, 0, 0), item[1])

    collected.sort(key=_sort_key, reverse=True)

    return VersionCandidates(
        candidates=collected[:5],
        current_date=current_date,
    )


# ---------------------------------------------------------------------------
# Container image tag lookup (Docker Registry v2)
# ---------------------------------------------------------------------------


def _fetch_all_tags(api_registry: str, docker_repo: str,
                    token: Optional[str]) -> Tuple[List[str], Optional[str]]:
    """Fetch all tags from a Docker Registry v2 API, following pagination.

    Returns (tags_list, error_message).
    """
    all_tags: List[str] = []
    url = f"https://{api_registry}/v2/{docker_repo}/tags/list?n={_TAG_PAGE_SIZE}"
    headers = {
        "Accept": "application/json",
        "User-Agent": "renovate-check/1.0",
    }
    if token:
        headers["Authorization"] = f"Bearer {token}"

    for _ in range(_MAX_TAG_PAGES):
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                data = json.loads(resp.read())

            tags = data.get("tags") or []
            all_tags.extend(tags)

            # Check Link header for next page
            link_hdr = resp.headers.get("Link", "")
            if 'rel="next"' not in link_hdr:
                break

            # Parse next URL from Link header
            for part in link_hdr.split(","):
                if 'rel="next"' in part:
                    match = re.search(r"<(.+?)>", part)
                    if match:
                        raw_next = match.group(1)
                        # next URL is relative to the registry; make it absolute
                        next_url = urllib.parse.urljoin(
                            f"https://{api_registry}", raw_next
                        )
                        url = next_url
                    else:
                        return all_tags, None
                    break
            else:
                break

        except urllib.error.HTTPError as e:
            return all_tags, f"HTTP {e.code} {e.reason}"
        except Exception as e:
            return all_tags, str(e)

    return all_tags, None


def get_latest_image_tag(registry: str, repository: str,
                         current_tag: str,
                         cache: VersionCache) -> VersionCandidates:
    """Query a Docker Registry v2 API for the newest semver image tags
    (excluding unstable prereleases).

    Returns up to 5 candidates, newest first.  Dates are NOT available from the
    tag-list API (manifest fetches would be needed), so ``current_date`` is
    always ``None``.
    """
    # Use cache for tags list
    tags_key = ("image_tags", f"{registry}/{repository}")
    version_tags: Optional[List[str]] = cache.get(tags_key)

    if version_tags is None:
        if "docker.io" in registry:
            api_registry = "registry-1.docker.io"
        else:
            api_registry = registry

        docker_repo = repository
        if api_registry == "registry-1.docker.io" and "/" not in repository:
            docker_repo = f"library/{repository}"

        token = None
        if api_registry == "registry-1.docker.io":
            token, auth_err = _get_oci_auth_token(api_registry, docker_repo)
            if not token:
                return VersionCandidates(error=auth_err or "docker hub auth failed")

        tags, err = _fetch_all_tags(api_registry, docker_repo, token)
        if err:
            return VersionCandidates(error=err)

        version_tags = sort_semver_tags(
            [t for t in tags if _SCAN_RE.match(t) and not is_prerelease(t)]
        )
        cache.put(tags_key, version_tags or [])

    candidates = [(t, "") for t in (version_tags or [])[:5]]
    return VersionCandidates(candidates=candidates)
