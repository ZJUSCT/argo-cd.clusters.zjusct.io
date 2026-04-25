# Cross Distro Linux Image Builder

## How to use

- See `config.yaml` for available build targets. A target is a combination of a base image and a set of modules to be installed on top of it.
- Run `make <target>` to build the image for the specified target. See the `Makefile` for details on how the build is executed.

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

## Find Distro Packages

- Cross Distro
    - https://pkgs.org/
    - https://repology.org/
- Debian: https://packages.debian.org/
- Ubuntu: https://packages.ubuntu.com/
- Fedora: https://apps.fedoraproject.org/packages/
- Arch: https://archlinux.org/packages/

## Tests

Scripts under `tests` are convienient scripts for operators to quickly check **in deployed instances** whether specific features are working as expected. They are not meant to be run in the build stage because they may require hardware support or runtime environment that is not available during the build stage.
