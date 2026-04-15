# AGENTS.md

必读文件：

- `README.md`：主项目 README
- `AGENTS.md`：AI 代理约束与指导原则

## 明确的非目标

在任何情况下，Agent 不允许执行以下操作，这些操作仅被允许由人类完成：

- 破坏性的 git 命令（force push、hard reset 等）
- 提交明文密钥或敏感信息
- 对数据进行破坏性的操作，如删除 DNS 记录、删除数据库等

除非明确请求或对变更严格必要，否则不应：

- 绕过 GitOps 流程直接修改 K8S 资源
- 在没有明确错误、性能或维护理由的情况下提议重构
- 重命名文件或资源
- 格式化无关代码
- 创建不必要的文档（如 TODO、CHANGELOG 等）
- 执行 git stash 等可能影响整个工作区的命令，因为可能有其他人类或 Agent 在并行工作

## 通用流程

本仓库的 Agent 执行任务时一般遵循以下流程：

- 了解现状：
    - 阅读项目中的配置文件
    - 使用 `kubectl` 等工具了解 K8S 集群的真实情况
- 梳理问题：
    - 阅读应用的文档、源码、Helm Chart、Kustomization 配置等，确保每一条配置、变更都有明确的来源和理由
    - 偏好顺序：官方提供的 Helm Chart/Kustomization 配置 > 第三方配置 > 手动编写配置
- 沟通确认：
    - 向人类报告执行计划，确认配置细节和变更范围
    - 提供清晰的背景信息、理由
- 执行变更：
    - 将变更内容提交到 Git 仓库，触发 Argo CD 同步
    - 按照确认的计划执行变更，并检查变更结果
    - Helm Value 文件应当用完整的默认值进行初始化，然后根据实际情况修改，避免遗漏重要配置项

## 问题排查与逻辑链路追踪

当遇到问题时，按以下顺序追踪：

1. **问题 → 当前方案**：我现在用什么来解决这个问题？
2. **当前方案 → 依赖组件**：这个方案依赖什么组件？
3. **依赖组件 → 实现细节**：最终的实现逻辑在哪里？

### 具体做法

- 不要急于搜索关键词
- 先画出完整的调用链路
- 从最终执行点逆推回来
- 每个跳转都要问自己："这里的机制是什么？"

### 信息查找优先级

1. **首先阅读用户明确提供的文件路径** - 用户主动提供的路径往往包含关键信息
2. **其次搜索本地仓库** - 本地仓库的配置是实际部署的依据
3. **最后才搜索外部源码** - 外部源码只是参考

关键原则：
- 当用户提供具体文件路径时，立即去读取该文件
- 不要假设外部源码比本地配置更重要
- 本地仓库的实际配置优先于通用最佳实践

## Git

Agent 提交 Git 时，必须用模型名署名 `Co-authored-by:`。举例：

- Claude 模型署名 `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
- Qwen 模型署名 `Co-authored-by: Qwen-Coder <qwen-coder@alibabacloud.com>`

模型应当根据自身的具体情况进行署名。

Agent 提交 Git 时必须按格式编写提交信息。示例：

```
feat(agent): update helm chart for nginx ingress
```

## 工具使用

- K8S 集群管理：`kubectl`、`kustomize`、`helm`
- K8S secret 管理：`kubeseal`
- K8S 持续部署：`argocd`

使用例：

- 验证配置：

    ```bash
    helm dependency build
    kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone
    ```

    对于非 kubectl 管理的资源（极少，例如 Tekton Pipeline Run），使用 `kubectl apply/create --dry-run=client` 来验证配置合法性。

- 应用变更：

    由 Argo CD 管理的资源应当通过 GitOps 流程部署，否则可能导致 Argo CD 同步出现问题。

    非 Argo CD 管理的测试、临时资源可以直接应用：

    ```bash
    kubectl apply --server-side -f -
    ```

    注意需要使用 server-side apply，否则某些资源可能因为 annotation 太长而失败，参考 [The ConfigMap is invalid: metadata.annotations: Too long: must have at most 262144 characters · Issue #820 · argoproj/argo-cd](https://github.com/argoproj/argo-cd/issues/820)。

- 加密 secret：

    ```bash
    kubectl create secret generic <name> \
        --from-literal=key=value \
        --dry-run=client -o yaml | \
    kubeseal --format yaml > resources/<name>-sealedsecret.yaml
    kubeseal --validate -f resources/<name>-sealedsecret.yaml
    ```

## 经验

- 执行复杂命令时（不管是在 K8S Pod 还是本地）建议先在本地写好脚本，然后拷贝到目标环境执行。否则可能出现格式、转义等问题。

## 升级

本节描述 K8S 服务升级流程，Agent 应当严格按照本节描述的流程进行服务升级。

1. 查询新版本：
    - 运行 scripts/check-version.py 查询是否有可升级的版本。该脚本自动从上游获取已发布超过 7 天的最新稳定版。
    - 注意配置文件中是否有关于版本升级的特殊说明，例如 Overleaf 依赖老版本 MongoDB，注释中有说明不应升级。
    - 一次会话仅迁移一个命名空间下的服务，不要同时对多个服务进行升级，以免出现混乱。
2. 进行配置文件迁移：
    - Helm Chart：
        1. 生成旧版本上游默认值 `charts/<chart>-<version>/<chart>/values.yaml` 与当前仓库中的 `values/<chart>-<version>.yaml` 的 Diff 文件。这个 Diff 文件表示“我们相对上游做了哪些定制”，后续迁移必须以它为依据，而不是凭感觉修改。
        2. 修改 `kustomization.yaml` 中的 Chart 版本，执行 `kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone`，令 Kustomize 自动拉取新版本 Chart。然后将新版本 Chart 自带的默认值文件 `charts/<chart>-<new_version>/<chart>/values.yaml` 复制为 `values/<chart>-<new_version>.yaml`，作为迁移起点。
        3. 基于第 1 步得到的 Diff，逐项、手工地将旧定制迁移到新的 `values/<chart>-<new_version>.yaml` 中。核心目标是保持与新上游默认值之间的 Diff **尽可能小且清晰**，使后续审阅者能够一眼看出“哪些行是我们有意修改的”。
            - 禁止直接复制旧的 `values/<chart>-<version>.yaml` 覆盖新文件，这会把上游新增字段、注释、格式调整、默认值写法一并抹掉，导致 Diff 噪音很大。
            - 禁止为了“结果等价”而保留旧文件中的格式细节；例如上游已改为 `podSecurityContext: {}`，就不要继续写成两行形式；上游新增了注释或默认字段，也应保留。
            - 每迁移一处配置，都应尽量在新文件中直接修改对应字段，而不是连带改动周围无关内容。
            - 迁移完成后，应再次比较 `charts/<chart>-<new_version>/<chart>/values.yaml` 与 `values/<chart>-<new_version>.yaml`，确认 Diff 只包含业务上确有必要的定制项，不包含无意义的格式漂移、注释缺失、空值写法差异等噪音。
            - 如果新版本 Value 文件发生结构变化，则按具体情况处理：字段仅移动位置时，在新位置重新施加同一项定制；字段被删除、重命名、语义改变或引入了新功能时，需要先分析影响，再向用户报告并沟通确认。
        4. 确认迁移完成后，删除旧的 Value 文件，并更新 `kustomization.yaml` 中对应的 `valuesFile` 路径。
        5. 运行 `helm dependency build`（如适用）和 `kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone` 验证配置合法性。
    - Raw Resource：TODO
3. 向用户报告配置文件迁移结果。报告不应只说“已经升级完成”，而应当按固定结构说明迁移结论，帮助用户快速判断本次升级的风险、影响与后续动作。建议至少包含以下内容：
    - **本次更新**：说明服务名、Chart 版本变化、对应应用版本变化。例如：`headlamp 0.40.0 -> 0.41.0`，或 `harbor chart 1.18.2 -> 1.18.3，对应 app 2.14.2 -> 2.14.3`。
    - **上游 Values 变更**：总结新旧上游默认值之间发生了什么变化。
        - 如果只有镜像 Tag、Chart 元数据、注释等小改动，应明确说明“上游 Values 基本无结构性变化，本次主要是版本号/镜像版本更新”。
        - 如果新增了字段、删除了字段、字段语义变化、默认值变化、暴露方式变化、存储行为变化、安全相关默认值变化等，应逐条列出。
    - **对我们的影响**：说明这些上游变更对当前仓库配置的实际影响。
        - 哪些变更对我们无影响，为什么无影响。
        - 哪些变更要求我们迁移字段位置、调整配置写法或新增配置。
        - 哪些变更可能影响运行时行为、兼容性、资源占用、数据路径、访问方式或安全性。
    - **本次迁移结果**：说明我们最终保留了哪些定制项，是否实现了与新上游默认值的最小 Diff，是否删除了旧 values 文件，是否更新了 `kustomization.yaml`。
    - **验证结果**：明确列出运行了哪些验证命令，以及结果是否通过。例如 `helm dependency build`、`kubectl kustomize --enable-helm --load-restrictor=LoadRestrictionsNone`。
    - **后续注意事项**：提示升级后需要重点关注的内容，例如首次启动时间、数据库迁移、镜像同步、访问路径变化、新增告警、废弃字段、行为变化等。如果没有特别注意事项，也应明确写“暂未发现需要特别关注的额外事项”。
    - **待用户确认事项**：如果升级过程中遇到语义变化、新增功能开关、废弃字段替代方案、潜在破坏性调整等，需要明确列出“哪些点需要用户决策”，而不是直接替用户拍板。

    推荐输出顺序为：**本次更新** → **上游 Values 变更** → **对我们的影响** → **本次迁移结果** → **验证结果** → **后续注意事项/待确认事项**。

    如果用户有任何问题或需要进一步的解释，提供详细的说明和帮助。
4. 提交 Git，由用户推送到远程仓库，触发 Argo CD 同步。
5. 监控升级过程，检查升级后服务的状态和日志，确保服务正常运行。如果出现问题，按照排查流程进行问题排查，并及时向用户报告问题和解决方案。
