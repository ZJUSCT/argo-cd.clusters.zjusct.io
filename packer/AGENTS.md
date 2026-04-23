# packer

Modular multiple distro image builder.

Usage:

```bash
make <config>
```

Each config can specify a base cloud-init image and a set of modules to run on top of it.

```yaml
- name: ubuntu-20.04-amd64-ascend
  arch: x86_64
  iso_url: https://mirrors.cernet.edu.cn/ubuntu-cloud-images/focal/current/focal-server-cloudimg-amd64.img
  iso_checksum: file:https://mirrors.cernet.edu.cn/ubuntu-cloud-images/focal/current/SHA256SUMS
  modules:
    - 50-test
```

## 跨发行版模块设计

模块运行在目标镜像内（通过 Packer SSH），由 `common.sh` 提供通用函数（`install_pkg`、`install_pkg_from_url` 等），各模块通过 `source common.sh` 引入。

### 分派机制

使用 `case $ID` 做发行版分派，利用 `;;&`（bash 4+）fall-through 实现继承。

```bash
case $ID in
ubuntu)
    # ubuntu 专属逻辑
    ;;&
debian)
    # debian 家族共用逻辑（ubuntu 会 fall-through 到这里）
    ;;
fedora)
    # fedora 专属逻辑
    ;;&
openeuler)
    # openEuler 专属逻辑
    ;;
arch)
    ;;
*)
    echo "Unsupported distro: $ID"
    exit 1
    ;;
esac
```

禁止使用旧项目的 `check_and_exec` 函数分派模式（定义 `debian()` 等函数再调用）。

### 三个维度

模块可能需要同时考虑：

- **架构**（`$ARCH`）：x86_64、arm64、riscv64
- **发行版**（`$ID`）：ubuntu、debian、fedora、openeuler、arch
- **发行版代数**（`$VERSION_ID`）：20.04、13、43 等

维度判断应在模块入口处完成，尽早跳过不支持的组合，避免执行到一半失败。

### 失败策略

根据模块的必要性选择：

- **必要模块**：不支持的发行版/架构应 `exit 1`，阻止构建继续
- **可选模块**：不支持的组合应打印信息后 `exit 0`，允许构建继续

```bash
# 可选模块示例
case $ID in
ubuntu|debian) ;;
arch)
    echo "Skipping: not applicable for $ID"
    exit 0
    ;;
*) ;;
esac
```
