#!/usr/bin/env python3

import argparse
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

QEMU_ARCH = {
    "amd64": "x86_64",
    "arm64": "aarch64",
    "riscv64": "riscv64",
}

MACHINE_TYPE = {
    "amd64": "pc",
    "arm64": "virt",
    "riscv64": "virt",
}

FIRMWARE_PATHS = {
    ("linux", "amd64"): (
        "/usr/share/OVMF/OVMF_CODE_4M.fd",
        "/usr/share/OVMF/OVMF_VARS_4M.fd",
    ),
    ("linux", "arm64"): (
        "/usr/share/AAVMF/AAVMF_CODE.fd",
        "/usr/share/AAVMF/AAVMF_VARS.fd",
    ),
    ("linux", "riscv64"): (
        "/usr/share/qemu-efi-riscv64/RISCV_VIRT_CODE.fd",
        "/usr/share/qemu-efi-riscv64/RISCV_VIRT_VARS.fd",
    ),
    ("darwin", "arm64"): (
        "/opt/homebrew/opt/qemu/share/qemu/edk2-aarch64-code.fd",
        "/opt/homebrew/opt/qemu/share/qemu/edk2-arm-vars.fd",
    ),
}

# platform.machine() returns "x86_64" on Linux, normalize to Go-style
GOARCH_MAP = {
    "x86_64": "amd64",
    "aarch64": "arm64",
}


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
                f'error: module "{m}" is deprecated and cannot be selected',
                file=sys.stderr,
            )
            sys.exit(1)
        modules.append(path)

    # Sort all modules together by filename for correct execution order
    modules.sort(key=os.path.basename)

    return modules


def resolve_variables(entry):
    host_os = platform.system().lower()
    host_arch = GOARCH_MAP.get(platform.machine(), platform.machine())

    arch = entry.get("arch")
    if not arch:
        print(f'error: "{entry["name"]}" missing arch', file=sys.stderr)
        sys.exit(1)

    # macOS only supports arm64
    if host_os == "darwin" and arch != "arm64":
        print(
            f"error: macOS only supports arm64 targets, got {arch}",
            file=sys.stderr,
        )
        sys.exit(1)

    # Accelerator
    if host_os == "linux" and host_arch == arch and os.path.exists("/dev/kvm"):
        accelerator = "kvm"
    elif host_os == "darwin" and host_arch == arch:
        accelerator = "hvf"
    else:
        accelerator = "tcg"
        print(
            "warning: accelerator not found, build will use TCG emulation (slow)",
            file=sys.stderr,
        )

    # CPU model
    cpu_model = "host" if accelerator != "tcg" else "max"

    # QEMU binary and machine type
    qemu_binary = f"qemu-system-{QEMU_ARCH[arch]}"
    machine_type = MACHINE_TYPE[arch]

    # EFI firmware
    firmware_key = (host_os, arch)
    if firmware_key not in FIRMWARE_PATHS:
        print(
            f"error: no firmware path defined for {host_os}/{arch}",
            file=sys.stderr,
        )
        sys.exit(1)
    efi_firmware_code, efi_firmware_vars = FIRMWARE_PATHS[firmware_key]

    return {
        "qemu_binary": qemu_binary,
        "machine_type": machine_type,
        "cpu_model": cpu_model,
        "accelerator": accelerator,
        "efi_firmware_code": efi_firmware_code,
        "efi_firmware_vars": efi_firmware_vars,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("target")
    parser.add_argument("--debug", action="store_true")
    args = parser.parse_args()

    target = args.target
    debug = args.debug
    config = load_config()
    entry = find_entry(config, target)

    if entry is None:
        available = [e["name"] for e in config if "name" in e]
        print(f'error: unknown target "{target}"', file=sys.stderr)
        print("available targets:", file=sys.stderr)
        for name in available:
            print(f"  {name}", file=sys.stderr)
        sys.exit(1)

    script_dir = os.path.dirname(os.path.abspath(__file__))
    output_dir = os.path.join(script_dir, "output")
    os.makedirs(output_dir, exist_ok=True)

    if debug:
        iso_url = os.path.join(output_dir, target, f"{target}.qcow2")
        if not os.path.isfile(iso_url):
            print(f'error: image not found: {iso_url}', file=sys.stderr)
            sys.exit(1)
        vm_name = "debug"
        iso_checksum = "none"
        modules = []
    else:
        iso_url = entry.get("iso_url")
        if not iso_url:
            print(f'skipping "{target}": missing iso_url', file=sys.stderr)
            sys.exit(0)

        iso_checksum = entry.get("iso_checksum")
        if not iso_checksum:
            print(f'skipping "{target}": missing iso_checksum', file=sys.stderr)
            sys.exit(0)

        vm_name = target
        modules = gather_modules(entry)

    resolved = resolve_variables(entry)

    var_file = os.path.join(output_dir, f".{vm_name}.auto.pkrvars.json")
    variables = {
        **resolved,
        "vm_name": vm_name,
        "iso_url": iso_url,
        "iso_checksum": iso_checksum,
        "modules": modules,
    }
    with open(var_file, "w") as f:
        json.dump(variables, f, indent=2)

    env = os.environ.copy()
    env["PACKER_LOG"] = "1"
    env["PACKER_LOG_PATH"] = os.path.join(output_dir, f"{vm_name}.log")

    build_target = "debug.qemu.packer" if debug else "build.qemu.packer"
    cmd = ["packer", "build", "-only=" + build_target]
    if not debug:
        cmd.append("-on-error=abort")
    cmd += [f"-var-file={var_file}", "."]
    sys.exit(subprocess.run(cmd, env=env).returncode)


if __name__ == "__main__":
    main()
