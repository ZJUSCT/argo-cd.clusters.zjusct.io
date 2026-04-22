#!/usr/bin/env python3

import json
import os
import platform
import subprocess
import sys

import yaml

CONFIG_PATH = "config.yaml"


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def find_entry(config, name):
    for entry in config:
        if entry.get("name") == name:
            return entry
    return None


def main():
    if len(sys.argv) < 2:
        print(f"usage: packer.py <target>", file=sys.stderr)
        sys.exit(1)

    target = sys.argv[1]
    config = load_config()
    entry = find_entry(config, target)

    if entry is None:
        available = [e["name"] for e in config if "name" in e]
        print(f"error: unknown target \"{target}\"", file=sys.stderr)
        print(f"available targets:", file=sys.stderr)
        for name in available:
            print(f"  {name}", file=sys.stderr)
        sys.exit(1)

    iso_url = entry.get("iso_url")
    if not iso_url:
        print(f"skipping \"{target}\": missing iso_url", file=sys.stderr)
        sys.exit(0)

    iso_checksum = entry.get("iso_checksum")
    if not iso_checksum:
        print(f"skipping \"{target}\": missing iso_checksum", file=sys.stderr)
        sys.exit(0)

    arch = entry.get("arch")
    if not arch:
        print(f"error: \"{target}\" missing arch", file=sys.stderr)
        sys.exit(1)

    modules = entry.get("modules", [])
    module_paths = [f"modules/{m}.sh" for m in modules]

    host_arch = platform.machine()

    if host_arch == arch and not os.path.exists("/dev/kvm"):
        print("warning: /dev/kvm not found, build will use TCG emulation (slow)", file=sys.stderr)

    var_file = f".{target}.auto.pkrvars.json"
    variables = {
        "arch": arch,
        "host_arch": host_arch,
        "vm_name": target,
        "iso_url": iso_url,
        "iso_checksum": iso_checksum,
    }
    if module_paths:
        variables["modules"] = module_paths
    with open(var_file, "w") as f:
        json.dump(variables, f, indent=2)

    cmd = ["packer", "build", "-on-error=abort", f"-var-file={var_file}", "."]
    sys.exit(subprocess.run(cmd, env=os.environ).returncode)


if __name__ == "__main__":
    main()
