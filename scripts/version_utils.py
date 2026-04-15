"""Shared utilities for Helm chart and container image version lookups."""

import json
import re
import time
import urllib.request
import urllib.error
import urllib.parse
from datetime import datetime, timezone, timedelta
from pathlib import Path
from typing import Dict, List, Optional, Tuple

try:
    import yaml
except ImportError:
    raise SystemExit("Error: PyYAML not installed. Install with: pip install pyyaml")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

HARBOR_PREFIX = "harbor.clusters.zjusct.io/"

_SCAN_RE = re.compile(r"^v?\d+\.\d+\.\d+")
_PRERELEASE_RE = re.compile(r"^v?\d+\.\d+\.\d+[-.]", re.IGNORECASE)

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
    """Simple dict-based cache keyed by (type, identifier)."""

    def __init__(self) -> None:
        self._data: Dict[Tuple[str, str], Optional[str]] = {}

    def get(self, key: Tuple[str, str]) -> Optional[str]:
        return self._data.get(key)

    def put(self, key: Tuple[str, str], value: Optional[str]) -> None:
        self._data[key] = value


# ---------------------------------------------------------------------------
# YAML helpers
# ---------------------------------------------------------------------------

def load_yaml(file_path: Path) -> Optional[dict]:
    """Load and parse a YAML file."""
    try:
        with open(file_path, "r") as f:
            return yaml.safe_load(f)
    except FileNotFoundError:
        return None
    except yaml.YAMLError:
        return None


def is_prerelease(version: str) -> bool:
    """True if *version* looks like a pre-release (contains ``-alpha``, ``-beta``, etc.)."""
    return bool(_PRERELEASE_RE.match(version))


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


def sort_semver_tags(tags: List[str]) -> List[str]:
    """Return *tags* sorted descending by semver (latest first)."""
    tagged = [(parse_semver(t), t) for t in tags if parse_semver(t) is not None]
    tagged.sort(key=lambda x: x[0], reverse=True)
    return [t for _, t in tagged]


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
                                 cache: VersionCache) -> Tuple[Optional[str], Optional[str]]:
    """Query an HTTP Helm repo ``index.yaml`` for the latest stable chart version
    that is at least 7 days old.

    Returns *(version, error_message)*.
    """
    key = ("helm_http", f"{repo_url}/{chart_name}")
    cached = cache.get(key)
    if cached is not None:
        return cached, None

    if not repo_url.endswith("/"):
        repo_url += "/"
    index_url = repo_url + "index.yaml"

    try:
        req = urllib.request.Request(index_url)
        req.add_header("User-Agent", _helm_user_agent())
        with urllib.request.urlopen(req, timeout=15) as resp:
            index_data = yaml.safe_load(resp.read())
    except urllib.error.HTTPError as e:
        cache.put(key, None)
        return None, f"HTTP {e.code} {e.reason}"
    except Exception as e:
        cache.put(key, None)
        return None, str(e)

    entries = index_data.get("entries", {})
    chart_entries = entries.get(chart_name, [])
    if not chart_entries:
        cache.put(key, None)
        return None, "chart not found in index"

    for entry in chart_entries:
        ver = entry.get("version", "")
        created = entry.get("created", "")
        if ver and not is_prerelease(ver) and _is_old_enough(created):
            cache.put(key, ver)
            return ver, None

    cache.put(key, None)
    return None, "no stable version at least 7 days old"


def get_latest_helm_version_oci(chart_name: str, repo_url: str,
                                cache: VersionCache) -> Tuple[Optional[str], Optional[str]]:
    """Query an OCI registry for the latest stable Helm chart version that is
    at least 7 days old.

    Returns *(version, error_message)*.
    """
    key = ("helm_oci", f"{repo_url}/{chart_name}")
    cached = cache.get(key)
    if cached is not None:
        return cached, None

    try:
        parsed = urllib.parse.urlparse(repo_url)
        registry = parsed.netloc
        path_part = parsed.path.strip("/")
        image = f"{path_part}/{chart_name}" if path_part else chart_name

        # Docker Hub remapping
        if "docker.io" in registry:
            api_registry = "registry-1.docker.io"
        else:
            api_registry = registry

        docker_image = image
        if api_registry == "registry-1.docker.io" and "/" not in image:
            docker_image = f"library/{image}"

        token, auth_err = _get_oci_auth_token(api_registry, docker_image)
        if auth_err:
            cache.put(key, None)
            return None, auth_err

        tags, tags_err = _fetch_oci_tags(api_registry, docker_image, token)
        if tags_err:
            cache.put(key, None)
            return None, tags_err
        if not tags:
            cache.put(key, None)
            return None, "no tags found"

        version_tags = sort_semver_tags(
            [t for t in tags if _SCAN_RE.match(t) and not is_prerelease(t)]
        )
        if not version_tags:
            cache.put(key, None)
            return None, "no stable semver tags found"

        for tag in version_tags[:_MAX_OCI_CANDIDATES]:
            created, created_err = _get_oci_manifest_created(
                api_registry, docker_image, tag, token
            )
            if created_err:
                continue
            if _is_old_enough(created):
                cache.put(key, tag)
                return tag, None

        cache.put(key, None)
        return None, "no stable OCI chart version at least 7 days old"

    except Exception as e:
        cache.put(key, None)
        return None, str(e)


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
                         cache: VersionCache) -> Tuple[Optional[str], Optional[str]]:
    """Query a Docker Registry v2 API for the latest semver image tag.

    Returns (latest_tag, error_message).
    """
    key = ("image", f"{registry}/{repository}")
    cached = cache.get(key)
    if cached is not None:
        return (cached, None)

    # Determine API registry
    if "docker.io" in registry:
        api_registry = "registry-1.docker.io"
    else:
        api_registry = registry

    # Docker Hub library prefix
    docker_repo = repository
    if api_registry == "registry-1.docker.io" and "/" not in repository:
        docker_repo = f"library/{repository}"

    # Auth
    token = None
    if api_registry == "registry-1.docker.io":
        token, auth_err = _get_oci_auth_token(api_registry, docker_repo)
        if not token:
            cache.put(key, None)
            return (None, auth_err or "docker hub auth failed")

    tags, err = _fetch_all_tags(api_registry, docker_repo, token)
    if err:
        cache.put(key, None)
        return (None, err)

    version_tags = sort_semver_tags(
        [t for t in tags if _SCAN_RE.match(t) and not is_prerelease(t)]
    )
    latest = version_tags[0] if version_tags else None
    cache.put(key, latest)
    return (latest, None)
