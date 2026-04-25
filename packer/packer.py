#!/usr/bin/env python3

import json
import os
import platform
import subprocess
import sys

import yaml

CONFIG_PATH = "config.yaml"
MODULES_ALWAYS = "modules-always"
MODULES_DEPRECATED = "modules-deprecated"
MODULES_OPTIONAL = "modules-optional"


def load_config():
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def find_entry(config, name):
    for entry in config:
        if entry.get("name") == name:
            return entry
    return None


def gather_modules(entry):
    modules = []

    # always modules
    for f in os.listdir(MODULES_ALWAYS):
        if f.endswith(".sh"):
            modules.append(f"{MODULES_ALWAYS}/{f}")

    # optional modules: user-selected
    for m in entry.get("modules", []):
        path = f"{MODULES_OPTIONAL}/{m}.sh"
        if not os.path.isfile(path):
            print(f"error: optional module not found: {m}.sh", file=sys.stderr)
            sys.exit(1)
        if os.path.isfile(f"{MODULES_DEPRECATED}/{m}.sh"):
            print(
                f"error: module \"{m}\" is deprecated and cannot be selected",
                file=sys.stderr,
            )
            sys.exit(1)
        modules.append(path)

    # Sort all modules together by filename for correct execution order
    modules.sort(key=os.path.basename)

    return modules


def main():
    if len(sys.argv) < 2:
        print("usage: packer.py <target>", file=sys.stderr)
        sys.exit(1)

    target = sys.argv[1]
    config = load_config()
    entry = find_entry(config, target)

    if entry is None:
        available = [e["name"] for e in config if "name" in e]
        print(f'error: unknown target "{target}"', file=sys.stderr)
        print("available targets:", file=sys.stderr)
        for name in available:
            print(f"  {name}", file=sys.stderr)
        sys.exit(1)

    iso_url = entry.get("iso_url")
    if not iso_url:
        print(f'skipping "{target}": missing iso_url', file=sys.stderr)
        sys.exit(0)

    iso_checksum = entry.get("iso_checksum")
    if not iso_checksum:
        print(f'skipping "{target}": missing iso_checksum', file=sys.stderr)
        sys.exit(0)

    arch = entry.get("arch")
    if not arch:
        print(f'error: "{target}" missing arch', file=sys.stderr)
        sys.exit(1)

    modules = gather_modules(entry)

    host_arch = platform.machine()

    if host_arch == arch and not os.path.exists("/dev/kvm"):
        print("warning: /dev/kvm not found, build will use TCG emulation (slow)", file=sys.stderr)

    output_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "output")
    os.makedirs(output_dir, exist_ok=True)

    var_file = os.path.join(output_dir, f".{target}.auto.pkrvars.json")
    variables = {
        "arch": arch,
        "host_arch": host_arch,
        "vm_name": target,
        "iso_url": iso_url,
        "iso_checksum": iso_checksum,
        "modules": modules,
    }
    with open(var_file, "w") as f:
        json.dump(variables, f, indent=2)

    env = os.environ.copy()
    env["PACKER_LOG"] = "1"
    env["PACKER_LOG_PATH"] = os.path.join(output_dir, f"{target}.log")

    cmd = ["packer", "build", "-on-error=abort", f"-var-file={var_file}", "."]
    sys.exit(subprocess.run(cmd, env=env).returncode)


if __name__ == "__main__":
    main()
