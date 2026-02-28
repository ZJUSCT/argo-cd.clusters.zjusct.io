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

## Git 署名

Agent 提交 Git 时，必须用模型名署名 `Co-authored-by:`。举例：

- Claude 模型署名 `Co-Authored-By: Claude Sonnet 4.6 <noreply@anthropic.com>`
- QWen 模型署名 `Co-authored-by: Qwen-Coder <qwen-coder@alibabacloud.com>`

模型应当根据自身的具体情况进行署名。

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

- 执行复杂命令时（不管是在 K8S Pod 还是本地）建议写脚本执行，否则可能出现格式、转义等问题
