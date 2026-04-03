#!/usr/bin/env python3
"""
Harbor declarative configuration script.

Reads config.yaml and .env, then applies Harbor settings via REST API (v2.0).
Idempotent: checks existing resources before creating/updating.

Usage:
    python configure_harbor.py              # dry-run (print planned changes)
    python configure_harbor.py --apply      # apply changes to Harbor
    python configure_harbor.py --apply -v   # verbose output
"""

import argparse
import logging
import os
import sys
from pathlib import Path

import requests
import yaml
from dotenv import load_dotenv

BASE_PATH = Path(__file__).resolve().parent
API_BASE = "/api/v2.0"

logger = logging.getLogger("harbor-config")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

class HarborError(Exception):
    """Raised when a Harbor API call fails."""


class HarborClient:
    def __init__(self, url: str, username: str, password: str):
        self.session = requests.Session()
        self.session.auth = (username, password)
        self.base = url.rstrip("/")
        self._registry_cache: dict[str, int] = {}
        self._dry_run = False
        self._csrf_token: str = ""
        self._fetch_csrf_token()

    def _fetch_csrf_token(self):
        """Obtain CSRF token required for POST/PUT requests.

        Harbor's CSRF middleware applies to /api/ paths when a session cookie
        is present.  The token is returned by GET /c/ctx in the
        X-Harbor-CSRF-Token header.
        """
        r = self.session.get(f"{self.base}/c/ctx")
        self._csrf_token = r.headers.get("X-Harbor-CSRF-Token", "")
        if not self._csrf_token:
            logger.warning("Could not obtain CSRF token from /c/ctx")
        else:
            self.session.headers["X-Harbor-CSRF-Token"] = self._csrf_token

    # -- generic request helpers --

    def _url(self, path: str) -> str:
        return f"{self.base}{API_BASE}{path}"

    def get(self, path: str, **kwargs) -> requests.Response:
        r = self.session.get(self._url(path), **kwargs)
        if r.status_code not in (200, 404):
            r.raise_for_status()
        return r

    def post(self, path: str, **kwargs) -> requests.Response:
        if self._dry_run:
            return requests.Response()
        r = self.session.post(self._url(path), **kwargs)
        return r

    def put(self, path: str, **kwargs) -> requests.Response:
        if self._dry_run:
            return requests.Response()
        r = self.session.put(self._url(path), **kwargs)
        return r

    # -- registry helpers --

    def list_registries(self) -> list[dict]:
        r = self.get("/registries", params={"page_size": 100})
        if r.status_code == 200:
            return r.json()
        return []

    def registry_id_by_name(self, name: str) -> int | None:
        if name in self._registry_cache:
            return self._registry_cache[name]
        for reg in self.list_registries():
            self._registry_cache[reg["name"]] = reg["id"]
        return self._registry_cache.get(name)

    def create_registry(self, reg: dict) -> int:
        """Create a registry endpoint. Returns the ID."""
        payload = {
            "name": reg["name"],
            "type": reg["type"],
            "insecure": reg.get("insecure", False),
        }
        if reg.get("url"):
            payload["url"] = reg["url"]
        if reg.get("description"):
            payload["description"] = reg["description"]
        if reg.get("credential"):
            payload["credential"] = reg["credential"]

        r = self.post("/registries", json=payload)
        if r.status_code == 201:
            loc = r.headers.get("Location", "")
            new_id = int(loc.split("/")[-1]) if loc else 0
            logger.info("  Created registry '%s' (id=%s)", reg["name"], new_id)
            self._registry_cache[reg["name"]] = new_id
            return new_id
        if r.status_code == 409:
            # already exists
            existing_id = self.registry_id_by_name(reg["name"])
            if existing_id:
                logger.info("  Registry '%s' already exists (id=%d)", reg["name"], existing_id)
            return existing_id
        logger.error("  Failed to create registry '%s': %d %s",
                     reg["name"], r.status_code, r.text)
        return None

    # -- project helpers --

    def list_projects(self) -> list[dict]:
        r = self.get("/projects", params={"page_size": 100})
        if r.status_code == 200:
            return r.json()
        return []

    def project_by_name(self, name: str) -> dict | None:
        for p in self.list_projects():
            if p["name"] == name:
                return p
        return None

    def create_project(self, proj: dict) -> None:
        existing = self.project_by_name(proj["name"])
        if existing:
            logger.info("  Project '%s' already exists (id=%d)", proj["name"], existing["project_id"])
            return

        payload: dict = {
            "project_name": proj["name"],
            "metadata": {
                "public": str(proj.get("public", False)).lower(),
            },
        }

        if proj.get("registry"):
            reg_id = self.registry_id_by_name(proj["registry"])
            if reg_id is None:
                logger.warning("  Registry '%s' not found, skipping proxy cache project '%s'",
                               proj["registry"], proj["name"])
                return
            payload["registry_id"] = reg_id

        if proj.get("storage_limit") is not None:
            payload["storage_limit"] = proj["storage_limit"]

        if proj.get("metadata"):
            payload["metadata"].update({k: str(v).lower() for k, v in proj["metadata"].items()})

        r = self.post("/projects", json=payload)
        if r.status_code == 201:
            logger.info("  Created project '%s'", proj["name"])
        else:
            logger.error("  Failed to create project '%s': %d %s",
                         proj["name"], r.status_code, r.text)

    # -- robot account helpers --

    def list_robots(self) -> list[dict]:
        r = self.get("/robots", params={"page_size": 100})
        if r.status_code == 200:
            return r.json()
        return []

    def create_robot(self, robot: dict) -> None:
        # Check for existing robot (project-level robots need different query)
        if robot["level"] == "project":
            namespace = robot["permissions"][0]["namespace"] if robot.get("permissions") else robot.get("project", "")
            project = self.project_by_name(namespace)
            if project:
                r = self.get("/robots", params={
                    "q": f"Level=project,ProjectID={project['project_id']}",
                    "page_size": 100,
                })
                existing = [rb for rb in (r.json() if r.status_code == 200 else [])
                            if rb["name"].endswith(f"+{robot['name']}")]
            else:
                existing = []
        else:
            existing = [
                rb for rb in self.list_robots()
                if rb["name"] == robot["name"] and rb["level"] == robot["level"]
            ]
        if existing:
            logger.info("  Robot '%s' (%s) already exists (id=%d)",
                        robot["name"], robot["level"], existing[0]["id"])
            return

        payload: dict = {
            "name": robot["name"],
            "level": robot["level"],
            "duration": robot.get("duration", -1),
            "disable": robot.get("disable", False),
            "permissions": robot.get("permissions", []),
        }
        if robot.get("description"):
            payload["description"] = robot["description"]
        if robot.get("secret"):
            payload["secret"] = robot["secret"]

        r = self.post("/robots", json=payload)
        if r.status_code == 201:
            logger.info("  Created robot '%s' (%s)", robot["name"], robot["level"])
            if r.text:
                data = r.json()
                logger.info("    Token: %s", data.get("secret", "(not returned)"))
        elif r.status_code == 409:
            logger.info("  Robot '%s' (%s) already exists", robot["name"], robot["level"])
        else:
            logger.error("  Failed to create robot '%s': %d %s",
                         robot["name"], r.status_code, r.text)

    # -- replication policy helpers --

    def list_policies(self) -> list[dict]:
        r = self.get("/replication/policies", params={"page_size": 100})
        if r.status_code == 200:
            return r.json()
        return []

    def _registry_ref(self, name: str) -> dict | None:
        """Build a minimal registry reference for replication policy."""
        if name == "local":
            return {"id": 0}
        reg_id = self.registry_id_by_name(name)
        if reg_id is None:
            return None
        return {"id": reg_id}

    def create_replication_policy(self, policy: dict) -> None:
        existing = [p for p in self.list_policies() if p["name"] == policy["name"]]
        if existing:
            logger.info("  Replication policy '%s' already exists (id=%d)",
                        policy["name"], existing[0]["id"])
            return

        src_ref = self._registry_ref(policy["src_registry"])
        dst_ref = self._registry_ref(policy["dest_registry"])
        if src_ref is None or dst_ref is None:
            missing = policy["src_registry"] if src_ref is None else policy["dest_registry"]
            logger.warning("  Registry '%s' not found, skipping replication policy '%s'",
                           missing, policy["name"])
            return

        payload: dict = {
            "name": policy["name"],
            "src_registry": src_ref,
            "dest_registry": dst_ref,
            "override": policy.get("override", False),
            "enabled": policy.get("enabled", False),
        }
        if policy.get("description"):
            payload["description"] = policy["description"]
        if policy.get("dest_namespace"):
            payload["dest_namespace"] = policy["dest_namespace"]
        if policy.get("dest_namespace_replace_count") is not None:
            payload["dest_namespace_replace_count"] = policy["dest_namespace_replace_count"]
        if policy.get("replicate_deletion") is not None:
            payload["replicate_deletion"] = policy["replicate_deletion"]
        if policy.get("speed") is not None:
            payload["speed"] = policy["speed"]

        # trigger
        if policy.get("trigger"):
            trigger = {"type": policy["trigger"]["type"]}
            if policy["trigger"].get("settings"):
                trigger["trigger_settings"] = policy["trigger"]["settings"]
            payload["trigger"] = trigger

        # filters
        if policy.get("filters"):
            payload["filters"] = [
                {"type": f["type"], "value": f["value"],
                 "decoration": f.get("decoration", "matches")}
                for f in policy["filters"]
            ]

        r = self.post("/replication/policies", json=payload)
        if r.status_code == 201:
            logger.info("  Created replication policy '%s'", policy["name"])
        else:
            logger.error("  Failed to create replication policy '%s': %d %s",
                         policy["name"], r.status_code, r.text)

    # -- system configuration --

    def update_system_config(self, config: dict) -> None:
        """Apply system configuration settings."""
        if not config:
            return
        logger.info("Applying system configuration (%d keys)", len(config))
        if self._dry_run:
            for k, v in config.items():
                logger.info("  %s = %s", k, v)
            return
        r = self.put("/configurations", json=config)
        if r.status_code == 200:
            logger.info("  System configuration updated")
        else:
            logger.warning("  Failed to update system config: %d %s", r.status_code, r.text)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def load_config() -> dict:
    config_path = BASE_PATH / "config.yaml"
    with open(config_path) as f:
        return yaml.safe_load(f) or {}


def main():
    parser = argparse.ArgumentParser(description="Declarative Harbor configuration")
    parser.add_argument("--apply", action="store_true", help="Apply changes (default: dry-run)")
    parser.add_argument("-v", "--verbose", action="store_true", help="Verbose output")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(message)s",
    )

    load_dotenv(BASE_PATH / ".env")
    harbor_url = os.environ.get("HARBOR_URL")
    harbor_user = os.environ.get("HARBOR_USERNAME")
    harbor_pass = os.environ.get("HARBOR_PASSWORD")

    if not all([harbor_url, harbor_user, harbor_pass]):
        logger.error("Missing HARBOR_URL, HARBOR_USERNAME or HARBOR_PASSWORD in .env")
        sys.exit(1)

    config = load_config()
    client = HarborClient(harbor_url, harbor_user, harbor_pass)
    client._dry_run = not args.apply

    mode = "APPLY" if args.apply else "DRY-RUN"
    logger.info("=== Harbor configuration [%s] ===", mode)

    system = config.get("system", {})
    registries = config.get("registries", [])
    projects = config.get("projects", [])
    robots = config.get("robot_accounts", [])
    replications = config.get("replication", [])
    total = sum(bool(v) for v in [system, registries, projects, robots, replications])

    step = 0
    if system:
        step += 1
        logger.info("[%d/%d] System settings", step, total)
        client.update_system_config(system)

    if registries:
        step += 1
        logger.info("[%d/%d] Registry endpoints (%d)", step, total, len(registries))
        for reg in registries:
            client.create_registry(reg)

    if projects:
        step += 1
        logger.info("[%d/%d] Projects (%d)", step, total, len(projects))
        for proj in projects:
            client.create_project(proj)

    if robots:
        step += 1
        logger.info("[%d/%d] Robot accounts (%d)", step, total, len(robots))
        for robot in robots:
            client.create_robot(robot)

    if replications:
        step += 1
        logger.info("[%d/%d] Replication policies (%d)", step, total, len(replications))
        for policy in replications:
            client.create_replication_policy(policy)

    logger.info("=== Done [%s] ===", mode)


if __name__ == "__main__":
    main()
