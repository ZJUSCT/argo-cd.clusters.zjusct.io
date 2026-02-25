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

那么运维团队要掌握什么呢？运维团队需要掌握系统的 Concept model。例如，运维 Tekton 这个 K8S 原生的 CI/CD 系统，运维只需要阅读 [Concept model | Tekton](https://tekton.dev/docs/concepts/concept-model/) 这一篇文章即可，然后直接指导 AI 来完成具体的配置、排障等工作。

## 文档

- `README.md`：AI 和人类工程师都应当阅读的总体介绍。
- `AGENTS.md`：参考 [AGENTS.md](https://agents.md/)。这里放置对 AI 的总体约束与指导原则，明确 AI 在本项目中的角色定位、能力边界与行为规范。
- 内容：注意不要堆砌文档，比如服务的 Git 配置文件中显而易见的事实不应当在文档中再次陈述。文档仅记录那些**不易从代码中直接获取、但对理解系统状态与设计决策至关重要的信息**，如设计决策的背景与权衡、服务间复杂依赖关系的解释、历史变更的上下文等。

## 仓库布局

- **`production/`** — 已经在生产环境中稳定部署的应用
- **`dev/`** — 用于开发/测试应用
- **`scripts/`** — 辅助脚本，如验证、部署等工具脚本`

## 应用部署

我们的 K8S 应用部署方法经过了四个阶段的迭代：

- [kubectl](https://kubernetes.io/docs/reference/kubectl/)：手动管理资源，缺乏版本控制和自动化
- [Helm](https://helm.sh/)：引入 Helm chart，提升了模板化和参数化能力，但难以管理模板以外的资源
- [Kustomize](https://kustomize.io/)：补足 Helm 的短板，实现所有 K8S 资源的声明式管理
- [Argo CD](https://argo-cd.readthedocs.io/)：实现了 GitOps 模式，自动同步 Git 仓库与集群状态

### Argo CD

- Argo CD 管理一个个 Application，它们可以是 Helm Chart、Kustomize 应用等
- Application 属于特定的 Project
- Application 可以由 ApplicationSet 自动生成
- 我们配置了 Application 和 ApplicationSet 的 Any Namespace 功能，以方便部署任意命名空间的应用

`dev/` 和 `production/` 目录各由一个 Argo CD ApplicationSet 管理，其核心机制是通过 Git 生成器将每个子目录映射为一个 Application，使用文件夹名作为名称和目标命名空间。具体配置见 [production/argo-cd/apps.yaml](production/argo-cd/apps.yaml)，其中的关键规则如下：

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

每个应用文件夹（`production/*` 或 `dev/*`）遵循此模式：

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

### Kustomize

Kustomize 通过 [HelmChartInflationGenerator](https://kubectl.docs.kubernetes.io/references/kustomize/builtins/#_helmchartinflationgenerator_) 管理 Helm Chart，但有不少缺点，我们采取了相应措施：

- 缺点：Kustomize 只会 Pull 一次 Chart 到 `charts/`（默认的 `chartHome` 目录），然后反复使用该本地副本进行渲染。未指定 `version` 时目录名为 `name`，指定 `version` 时目录名为 `name-version/name`。

    措施：

    - 通过 `version` 字段明确指定 Chart 的版本，否则本地渲染和 Argo CD 渲染时的版本可能不同。
    - `.gitignore` 排除 Kustomize 自动拉取的 Helm Chart，避免将其纳入版本控制。例外是一些自定义的 Helm Chart 可能需要被版本控制，举例：

        ```text
        charts/*
        !charts/freeipa
        ```

- 缺点：Kustomize 不会预先运行 `helm dependency build`，导致如果 Chart 有依赖关系时渲染失败。见 [Allow building helm dependencies when dealing with local charts · Issue #5851 · kubernetes-sigs/kustomize](https://github.com/kubernetes-sigs/kustomize/issues/5851)。

    措施：

    - Argo CD 需要使用 [Config Management Plugins - Argo CD - Declarative GitOps CD for Kubernetes](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/)，相关配置见 `production/argo-cd/plugin.yaml`。参考 [You may need to run `helm dependency build` to fetch missing dependencies: · Issue #11564 · argoproj/argo-cd](https://github.com/argoproj/argo-cd/issues/11564)。

- 缺点：不支持 overlays 方式覆盖 Helm Chart 的 values
，见 [How to properly override helmChart values using overlays?](https://github.com/kubernetes-sigs/kustomize/issues/4658)

    我们暂时没有使用 Overlay 功能，不考虑这个问题。

### Helm

起初我们仅在 Value 文件中放置需要覆盖的值，但遇到了下列问题：

- 默认值变更：Helm Chart 默认值会随着版本更新而变化，仅覆盖部分值难以发现和适配这些变更。
- 比对困难：常常需要拿着 Chart 的默认值与覆盖值进行对比，心智负担较重。
- AI 幻觉：如果不提供完整的默认值，AI 可能会编造配置导致错误。

为了解决上述问题，`values/<name>-<version>.yaml` 均复制自相应版本 Helm Chart 的默认值 `charts/<name>-<version>/<name>/values.yaml`，修改后可使用 [dyff](https://github.com/homeport/dyff) 与默认值清晰比对。

**命名规范**：values 文件必须命名为 `values/<chart-name>-<version>.yaml` 格式，以明确对应的 Chart 版本。

### pre-commit

pre-commit 将对本节前述内容进行检查，步骤如下：

- 检查 `kustomization.yaml` 中 `helmCharts` 字段：

    ```yaml
    # repo 和 version 要么同时存在，要么都不存在（本地 Chart）
    repo:
    version:
    # 必须
    name:
    releaseName:
    namespace: # 与目录名相同
    includeCRDs: true
    valuesFile: values/<name>-<version>.yaml
    ```

- 检查 Helm Chart 是否有新版本，若有则提示更新。
- 本地构建 Kustomize 确保能成功渲染。

## K8S 集群现状和部署指南

本节记录 `production/` 目录下部署的服务及其配置要点。

| 项目主页 | 社区 |
| --- | --- |
| [refector](https://github.com/emberstack/kubernetes-reflector) | 未知 |
| [kubelet-csr-approver](https://github.com/postfinance/kubelet-csr-approver) | 公司：PostFinance |
| [FreeIPA](https://www.freeipa.org/) | 公司：RedHat |
| [buildkit](https://buildkit.github.io/) | 公司：Docker |
| [GitLab Runner](https://docs.gitlab.com/runner/) | 公司：GitLab |
| [Ingress Nginx](https://kubernetes.github.io/ingress-nginx/) | Kubernetes SIG Network(Deprecated) |
| [metrics-server](https://kubernetes-sigs.github.io/metrics-server/) | Kubernetes SIG Instrumentation |
| [Argo CD](https://argo-cd.readthedocs.io/) | Linux Foundation - CNCF |
| [Jenkins](https://www.jenkins.io/) | Linux Foundation - CD Foundation |
| [Tekton](https://tekton.dev/) | Linux Foundation - CD Foundation |
| [Metal3](https://metal3.io/) | Linux Foundation - CNCF |
| [OpenEBS](https://openebs.io/) | Linux Foundation |
| [Rook](https://rook.io/) | Linux Foundation - CNCF |
| [Harbor](https://goharbor.io/) | Linux Foundation - CNCF |
| [Dragonfly](https://d7y.io/) | Linux Foundation - CNCF |
| [Cilium](https://cilium.io/) | Linux Foundation - CNCF |
| [Envoy Gateway](https://www.envoyproxy.io/envoy-gateway) | Linux Foundation - CNCF |
| [cert-manager](https://cert-manager.io/) | Linux Foundation - CNCF |
| [Metallb](https://metallb.universe.tf/) | Linux Foundation - CNCF |
| [ExternalDNS](https://github.com/kubernetes-sigs/external-dns/) | Kubernetes SIG Network |

### 服务部署

- 获取 Helm Chart 及其版本，将 `values.yaml` 复制到 `values/<name>-<version>.yaml`，并根据需要修改覆盖值。

    ```bash
    helm search repo ...
    helm show values ...
    ```

- 放置 `.gitignore`，排除 Kustomize 自动拉取的 Helm Chart。
- 为服务配置外部访问：

    - 使用 Chart 内置的 Gateway API 或 Ingress。如果 Chart 不支持，则自行创建 HTTPRoute 资源。
    - 域名：`*.clusters.zjusct.io`、`*.s.zjusct.io`。如果应用支持多 Host 则前述域名均应当配置，否则仅配置第一个。

### production/argo-cd

Argo CD 作为 GitOps 的核心组件，负责将 Git 仓库中的声明式配置自动同步到 K8S 集群中。

Argo CD 在等待上一轮同步成功完成前不会执行新的同步，因此如果某个应用的同步失败了，后续的变更将无法部署到集群中。此时一般强制停止当前同步，然后 Argo CD 会触发新的同步，应用新的变更。

### production/default

#### cilium

作为 CNI 插件，并提供 LoadBalancer 功能。

- 地址段 `172.28.0.0/16`，通过 BGP 将路由信息通告到集群主路由。
- LoadBalancer IP 不会响应 ICMP，因此无法通过 ping 命令测试连通性。
- Pod 内无法访问 LoadBalancer IP。两种解决办法：

    - K8S 内应当通过 Service IP/DNS 访问相应服务，但内部往往没有 TLS（TLS 配置在 Gateway/Ingress 上），不适用于需要 TLS 的服务。
    - 使用 DNS Split Horizon 方法，通过 CoreDNS rewrite 将解析结果指向 Service IP，例：

        ```yaml
        - name: rewrite
          parameters: stop
          configBlock: |-
            name exact harbor.clusters.zjusct.io envoy-gateway.envoy-gateway.svc.cluster.local answer auto
        ```

#### harbor

集群搭建 Harbor 用于内网镜像服务，域名 `harbor.clusters.zjusct.io`。配置了知名 Registry 的 Pull Through Cache，将其添加为前缀即可。例如：

- `ubuntu` -> `harbor.clusters.zjusct.io/hub.docker.com/library/ubuntu`
- `quay.io/minio/minio` -> `harbor.clusters.zjusct.io/quay.io/minio/minio`

K8S 上部署的服务均应使用 Harbor 作为镜像前缀。`kustomization.yaml` 中使用 `image-prefix.yaml` 配置集群内镜像服务的前缀。

```yaml
transformers:
- ../../image-prefix.yaml
```

对于 Docker Hub 上的短镜像名，需要先通过 `images` 字段将其转换为完整镜像名，例如：

```yaml
images:
- name: ubuntu
    newName: docker.io/library/ubuntu
```

### production/ingress-nginx

提供 IngressClasses `nginx`，虽然使用广泛但已进入维护状态，建议使用更新的 Gateway API。

### production/envoy-gateway

提供 Gateway `envoy-gateway`，已配置下列 Listener

- 80：HTTP
- 443：HTTPS，已配置 TLS 泛域名证书
- 444：TLS Passthrough，适用于需要直接暴露 TLS 服务的应用

### production/dragonfly

P2P 文件分发。containerd 已启用集成，节点间 K8S 镜像将通过 P2P 方式分发。

### production/cert-manager

已配置 ACME 从 Let's Encrypt 获取 TLS 证书，用于 `*.clusters.zjusct.io` 域名。

其他用途（如内部服务）应当自行创建 `Issuer` 配置自签名证书。

### production/freeipa

FreeIPA 作为集群域控，提供 LDAP、DNS、Automount 等服务。ExternalDNS 自动将集群内 service、ingress 和 Gateway 相关的 DNS 记录同步到 FreeIPA 的 DNS 中。

### production/kube-system

seald secret

### production/metal3

裸金属节点管理。

TODO：命名空间迁移。目前 metal3 占据独立的 3 个命名空间，与仓库中其他应用不一致。

### production/openebs

提供本地存储 `openebs-hostpath`，适用于数据库等自身具有 Replica 功能、对读写性能有较高要求的应用。

### production/reflector

用于在命名空间间同步资源，参考 [Syncing Secrets Across Namespaces - cert-manager Documentation](https://cert-manager.io/docs/devops-tips/syncing-secrets-across-namespaces/)。

### production/rook-ceph

提供分布式存储：

- `ceph-block`：适用于需要高可用和弹性扩展的应用
- `ceph-filesystem`：适用于需要共享访问的应用
