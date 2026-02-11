# Argo CD

基本概念：

- Argo CD 管理一个个 Application，它们可以是 Helm Chart、Kustomize 应用等
- Application 属于特定的 Project
- Application 可以由 ApplicationSet 自动生成

## Any Namespace

为了方便部署任意命名空间，我们配置了 Application 和 ApplicationSet 的 Any Namespace 功能。主要改动包括：

- HelmChart 中几处 config param 配置
- default project 允许任意命名空间

## Kustomize + Helm 应用构建

Kustomize 对 Helm 的支持并不完善，有很多不方便的地方，例如：

- [How to properly override helmChart values using overlays?](https://github.com/kubernetes-sigs/kustomize/issues/4658)：不支持 overlays 方式覆盖 Helm Chart 的 values
- [Allow building helm dependencies when dealing with local charts · Issue #5851 · kubernetes-sigs/kustomize](https://github.com/kubernetes-sigs/kustomize/issues/5851)：kustomize 不会预先运行 helm dependency build，导致构建失败

这导致 Argo CD 也产生了问题：

- [You may need to run `helm dependency build` to fetch missing dependencies: · Issue #11564 · argoproj/argo-cd](https://github.com/argoproj/argo-cd/issues/11564)

解决方案是使用 [Config Management Plugins - Argo CD - Declarative GitOps CD for Kubernetes](https://argo-cd.readthedocs.io/en/stable/operator-manual/config-management-plugins/)，相关配置见 `production/argo-cd/plugin.yaml`。
