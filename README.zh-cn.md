# argo-cd.clusters.zjusct.io

本仓库是[浙江大学超算队（ZJUSCT）](https://www.zjusct.io)的 Kubernetes 集群 GitOps 配置中心，实现集群状态的声明式管理与持续同步。**本项目是一次面向 AI 辅助运维（AIOps）新范式的探索与实践。**

## 设计理念

本项目的设计理念可以用一句话概括：**让 AI 接管耗时巨大的信息处理工作**，从而使人类工程师能聚焦于系统的逻辑设计与架构决策。

传统运维工作的核心挑战，源于系统不断演进中积累的**固有复杂性**，以及随之而来的**信息传递与处理的高昂成本**。配置的意图、服务间的依赖、历史决策的上下文等信息，往往隐没在命令行历史、临时的环境变量或不完整的文档中，使得维护、排障与知识传承变得异常困难，系统状态也变得脆弱而模糊。

我们认为，以大型语言模型（LLM）为代表的 AI 技术，为改变这一现状提供了新的工具。其关键在于**明确划分 AI 与人类在运维工作中的不同角色**：

- **AI 应作为强大的信息处理器与聚合器**：LLM 擅长从海量、多源的文本（代码、配置、日志、文档）中快速检索、提取和总结信息。这意味着，它可以高效地替人类完成信息搜集、整理与初步归因等工作，将运维人员从繁琐的“信息考古”中解放出来。
- **人类必须始终掌控系统的逻辑思考与设计权**：必须清醒认识到，当前**基于概率统计的 LLM 并不具备真正的系统逻辑能力**。它无法理解架构设计的深层意图，无法在模糊地带做出负责任的权衡，也无法进行真正的创造性的抽象设计。对于“系统边界应如何划定”、“服务抽象是否合理”、“变更的长远影响是什么”这类需要逻辑推演、价值判断和创造性思维的核心问题，人类工程师的角色不可替代。

因此，我们所探索的范式是：**人类负责定义系统逻辑与架构（What & Why），AI 辅助人类高效地处理实现与状态信息（How & Current Status），双方在清晰的边界内协同工作。**

本仓库是这一理念的初步实践载体。我们尝试通过 GitOps 方法论，将集群的期望状态彻底代码化、版本化，致力于 **“将 Git 打造为系统状态唯一可靠的单一事实来源”**。这一实践旨在**减少**运行环境与声明式代码之间的信息差，从而为 AI 工具提供一个结构清晰、可追溯的分析基座，使其能够更可靠地辅助人类洞察系统状态、评估变更和定位问题。

在此框架下，AI 将被鼓励作为本仓库的主要日常操作者，在人类设定的逻辑框架与监督下，完成集群的运维工作。

## 文档

- 语言：运维团队主要使用中文进行交流，主要负责撰写 `.zh-cn.md` 结尾的中文文档。AI 负责将 `.zh-cn.md` 的内容翻译对应的 `.md` 文件，供国际开源社区参考等。
- `AGNETS.zh-cn.md`：参考 [AGENTS.md](https://agents.md/)。这里放置对 AI 的总体约束与指导原则，明确 AI 在本项目中的角色定位、能力边界与行为规范。
- 内容：注意不要堆砌文档，比如服务的 Git 配置文件中显而易见的事实不应当在文档中再次陈述。文档仅记录那些**不易从代码中直接获取、但对理解系统状态与设计决策至关重要的信息**，如设计决策的背景与权衡、服务间复杂依赖关系的解释、历史变更的上下文等。

## 约束

本 Git 仓库通过 pre-commit 钩子和 CI 流水线，强制执行以下约束：

- `dev/` 和 `production/` 目录下文件夹不能重名，以避免 ApplicationSet 模板中的命名冲突。
- 所有 Application 在推送前必须通过 kustomize build 或类似工具进行渲染测试，确保能生成有效的 Kubernetes 资源清单。
- 不允许关键凭据以明文形式出现在代码中，必须使用加密工具（如 Sealed Secrets）进行加密后存储。

## 仓库布局

### 顶层目录

- **`production/`** — 已经在生产环境中稳定部署的应用
- **`dev/`** — 用于开发/测试应用

`dev/` 和 `production/` 目录各由一个 Argo CD ApplicationSet 自动管理，其核心机制是通过 Git 生成器将每个子目录映射为一个 Application。具体配置见 [production/argo-cd/apps.yaml](production/argo-cd/apps.yaml)，其中的关键规则如下：

```yaml
generators:
    - git:
        directories:
        - path: production/*
template:
    metadata:
    name: '{{path.basename}}'
    namespace: '{{path.basename}}'
    spec:
    source:
        path: '{{path}}'
    destination:
        namespace: '{{path.basename}}'
```

因此其中每个文件夹将被视为一个 Application，使用文件夹名作为名称和目标命名空间。

- **`scripts/`** — 辅助脚本，如验证、部署等工具脚本`

### 应用布局

每个应用（`production/*` 或 `dev/*`）遵循此模式：

```text
namespace-name/
├── .gitignore
├── kustomization.yaml          # 主 Kustomize 配置
├── values/                      # Helm chart 值覆盖
│   ├── chart1.yaml
│   └── chart2.yaml
├── resources/                   # 自定义 Kubernetes 资源
│   ├── namespace.yaml
│   ├── configmaps.yaml
│   └── *-sealedsecret.yaml     # 加密密钥
└── charts/                      # 本地 Helm charts（如果需要）
    └── chart-name/
```

- 如果一个命名空间中的服务较多，可以在该命名空间的文件夹下创建子目录（如 `values` 和 `resources`）来组织 Helm chart 的值覆盖和 Kubernetes 资源定义。
- `.gitignore` 一般用于排除 `kustomize` 构建时自动拉取的 Helm Chart，这些文件不需要被版本控制。例外是一些自定义的 Helm Chart 可能需要被版本控制，举例：

    ```text
    charts/*
    !charts/freeipa
    ```

## K8S 集群现状和部署指南

### 存储

现有 StorageClass 及其适用场景：

- `openebs-hostpath`：基于 OpenEBS 的本地存储，适用于数据库等对读写性能有较高要求的应用
- `ceph-block`：适用于需要高可用和弹性扩展的应用
- `cephfs`：适用于需要共享访问的应用

### 网络

- CNI 插件：cilium，启用 Hubble 提供网络可观测性。
- IngressClasses：`nginx`，虽然使用广泛但已进入维护状态，建议使用更新的 Gateway API。
- Gateway：`envoy-gateway`，已配置下列 Listener
    - 80：HTTP
    - 443：HTTPS，已配置 TLS 泛域名证书
    - 444：TLS Passthrough，适用于需要直接暴露 TLS 服务的应用
- LoadBalancer：metallb，地址段 `172.28.0.0/16`。
- 域名：`*.clusters.zjusct.io`、`*.s.zjusct.io`。如果应用支持多 Host 则前述域名均应当配置，否则仅配置第一个。

### 镜像服务

集群搭建 Harbor 用于内网镜像服务，域名 `harbor.clusters.zjusct.io`。配置了知名 Registry 的 Pull Through Cache，将其添加为前缀即可。例如：

- `ubuntu` -> `harbor.clusters.zjusct.io/hub.docker.com/library/ubuntu`
- `quay.io/minio/minio` -> `harbor.clusters.zjusct.io/quay.io/minio/minio`

如果 Helm Chart 允许配置 imageRepository，则应添加集群内镜像服务的前缀。

### 应用部署

我们的 K8S 应用部署方法经过了四个阶段的迭代：

- [kubectl](https://kubernetes.io/docs/reference/kubectl/)：手动管理资源，缺乏版本控制和自动化
- [Helm](https://helm.sh/)：引入 Helm chart，提升了模板化和参数化能力，但难以管理模板以外的资源
- [Kustomize](https://kustomize.io/)：补足 Helm 的短板，实现所有 K8S 资源的声明式管理
- [Argo CD](https://argo-cd.readthedocs.io/)：实现了 GitOps 模式，自动同步 Git 仓库与集群状态
