# Cross Distro Linux Image Builder

## How to use

- See `config.yaml` for available build targets. A target is a combination of a base image and a set of modules to be installed on top of it.
- Run `make <target>` to build the image for the specified target. See the `Makefile` for details on how the build is executed.
- `packer.py` is the main script that resolves the variables in the target configuration, prepares the Packer variable file, and executes the Packer build command.

## Debug

```bash
python3 packer.py --debug <target_image>
```

Two methods are available for debugging(can be changed in build.pkr.hcl):

- SSH port 2222
- VNC port 5901

## Modules

There are three types of modules:

- `modules-always`: These modules are always included in the build, regardless of the target.
- `modules-optional`: Can be selected for inclusion in the build by adding their names to the `modules` list of a target in `config.yaml`.
- `modules-deprecated`: These modules are kept in the codebase for reference but are not included in any build targets.

Modules are gathered and sorted together by packer.py. Packer will execute them in order.

Common module patterns:

```bash
#!/usr/bin/env bash
# <description of the module>

# shellcheck disable=SC1091
source /tmp/00-shared.sh

# Each module should consider ARCH, ID, VERSION_ID compatibility
case "$ID" in
  debian|ubuntu)
    case "$VERSION_ID" in
      13|25.10)
        # <installation steps for debian 13 and ubuntu 25.10>
        ;;
      *)
        echo "Unsupported version: $VERSION_ID"
        exit 1
        ;;
    esac
    ;;
  *)
    echo "Unsupported distribution: $ID"
    exit 1
    ;;
esac

# Prefer long options to make the scripts more readable.

# Write file using install command to ensure correct permissions
install -D -m 0644 /dev/null /path/to/installed/file <<EOF
<content of the installed file>
EOF
```

## Running on K8S Tekton CI

The above instructions are for running the build locally. After the builds are tested locally, they will be run on the K8S Tekton CI pipeline.

## Agent Task Loop

1. Run user specified build command
    - The builds take a long time. Run them as background tasks and check log files under the output directory for the results.
    - No need to redirect output because the script already does that.
2. If the build command fails, investigate failure reason and propose a fix
    - Only trust official documentation and sources, do not propose fixes based on assumptions or incomplete information
    - Tools that agent can use to get knowledge about distros and test proposed fixes:
        - Temporary docker containers
        - Mount the cloud-init/built image as read-only and inspect the filesystem
3. Wait for user confirmation on the proposed fix
4. If user confirms the fix, apply the fix and go back to step 1

## Network

To speed up the build process, we always use HTTP cache proxy and mirrors.

- Cluster Squid HTTP/HTTPS cache proxy: `http://172.28.0.4:3128`. Make sure to install `squid.crt` to the trusted CA store to use the HTTPS proxy.
- Mirror:
    - General: `https://mirrors.cernet.edu.cn/`. Documents on how to use the mirror can be found at `https://help.mirrors.cernet.edu.cn/`.
    - NPM: `https://registry.npmmirror.com/`.

## Package Indexes

- Cross Distro:
    - https://pkgs.org/
    - https://repology.org/
- Debian: https://packages.debian.org/
- Ubuntu: https://packages.ubuntu.com/
- Fedora: https://apps.fedoraproject.org/packages/
- Arch: https://archlinux.org/packages/

## Names

Follow [OCI Image Index Specification](https://github.com/opencontainers/image-spec/blob/v1.0.2/image-index.md), which is the same as [Go Language Documentation](https://go.dev/doc/install/source#environment):

```text
$GOOS	$GOARCH
aix	ppc64
android	386
android	amd64
android	arm
android	arm64
darwin	amd64
darwin	arm64
dragonfly	amd64
freebsd	386
freebsd	amd64
freebsd	arm
illumos	amd64
ios	arm64
js	wasm
linux	386
linux	amd64
linux	arm
linux	arm64
linux	loong64
linux	mips
linux	mipsle
linux	mips64
linux	mips64le
linux	ppc64
linux	ppc64le
linux	riscv64
linux	s390x
netbsd	386
netbsd	amd64
netbsd	arm
openbsd	386
openbsd	amd64
openbsd	arm
openbsd	arm64
plan9	386
plan9	amd64
plan9	arm
solaris	amd64
wasip1	wasm
windows	386
windows	amd64
windows	arm
windows	arm64
```

If other tools returns different names, we need to map them to the above names. For example, `uname -m` may return `x86_64` for `amd64` and `aarch64` for `arm64`.
