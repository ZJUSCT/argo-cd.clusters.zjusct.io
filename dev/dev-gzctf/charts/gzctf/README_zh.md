# GZCTF Helm Chart

用于部署 [GZCTF](https://github.com/GZTimeWalker/GZCTF) 的 Helm Chart - 一个支持 Kubernetes 集成的现代化 CTF（夺旗赛）平台。

## 简介

GZCTF 是一个功能丰富的 CTF 平台，支持通过 Kubernetes 进行动态容器管理。本 Helm Chart 可将 GZCTF 及其依赖项（PostgreSQL 和 Garnet 缓存）部署到您的 Kubernetes 集群。

## 前置要求

- Kubernetes 1.19+
- Helm 3.0+
- 支持 PersistentVolume 的存储
- Ingress 控制器（可选，用于外部访问）

## 安装

### 快速开始

```bash
# 使用自定义配置安装
helm install my-gzctf ./gzctf -f values.yaml
```

### 使用自定义配置

创建 `custom-values.yaml` 文件：

```yaml
gzctf:
  config:
    database:
      password: "你的强密码"
    xorKey: "你的随机字符串"
    email:
      senderAddress: "noreply@yourdomain.com"
      password: "你的邮箱密码"
      smtp:
        host: smtp.qq.com
        port: 587
    containerProvider:
      publicEntry: "ctf.yourdomain.com"

  persistence:
    storageClassName: "你的存储类名称"

postgresql:
  persistence:
    storageClassName: "你的存储类名称"

ingress:
  enabled: true
  className: "nginx"
  hosts:
    - host: ctf.yourdomain.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ctf-tls
      hosts:
        - ctf.yourdomain.com
```

使用自定义配置安装：

```bash
helm install my-gzctf ./gzctf -f custom-values.yaml
```

## 配置说明

### 必须修改的配置

在生产环境部署前，以下配置**必须修改**：

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `gzctf.config.database.password` | PostgreSQL 数据库密码 | `CHANGE_ME_DATABASE_PASSWORD` |
| `gzctf.config.xorKey` | 敏感数据加密密钥 | `CHANGE_ME_RANDOM_STRING` |
| `gzctf.config.email.password` | SMTP 邮箱密码 | `CHANGE_ME_EMAIL_PASSWORD` |
| `gzctf.config.containerProvider.publicEntry` | 平台公网域名 | `internal.example.com` |

### 存储配置

配置数据和数据库的持久化存储：

```yaml
gzctf:
  persistence:
    enabled: true
    storageClassName: "你的存储类"  # 如 "standard", "nfs-client", "local-path"
    size: 4Gi

postgresql:
  persistence:
    enabled: true
    storageClassName: "你的存储类"
    size: 1Gi
```

### Ingress 配置

启用并配置 Ingress 以实现外部访问：

```yaml
ingress:
  enabled: true
  className: "nginx"  # 或 "traefik"、"alb" 等
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
  hosts:
    - host: ctf.yourdomain.com
      paths:
        - path: /
          pathType: Prefix
  tls:
    - secretName: ctf-tls
      hosts:
        - ctf.yourdomain.com
```

### HTTPRoute 配置（Gateway API）

Gateway API 是 Kubernetes 下一代流量路由 API，将逐步取代传统的 Ingress。使用 HTTPRoute：

**前置要求：**
- 安装 Gateway API CRD：`kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml`
- 部署 Gateway 控制器（如 Istio、Envoy Gateway、Cilium）
- 在集群中创建 Gateway 资源

**配置方式：**

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway      # Gateway 名称
      namespace: default     # Gateway 所在命名空间
  hostnames:
    - ctf.yourdomain.com
```

**高级路由示例：**

```yaml
httpRoute:
  enabled: true
  parentRefs:
    - name: my-gateway
      namespace: gateway-system
      sectionName: https    # 指定监听器
  hostnames:
    - ctf.yourdomain.com
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      filters:
        - type: RequestHeaderModifier
          requestHeaderModifier:
            set:
              - name: X-Forwarded-Proto
                value: https
      backendRefs:
        - name: gzctf       # 将自动生成为 <release-name>-gzctf
          port: 8080
```

## 访问 GZCTF

安装完成后，按照 NOTES 输出的说明操作：

```bash
# 通过端口转发进行本地访问
export POD_NAME=$(kubectl get pods -l "app.kubernetes.io/name=gzctf,app.kubernetes.io/instance=my-gzctf" -o jsonpath="{.items[0].metadata.name}")
kubectl port-forward $POD_NAME 8080:8080

# 然后访问 http://127.0.0.1:8080
```

如果启用了 Ingress，可以通过以下地址访问：
- https://ctf.yourdomain.com

## 卸载

```bash
helm uninstall my-gzctf
```

**注意**：此操作不会删除 PersistentVolumeClaim。如需删除：

```bash
kubectl delete pvc -l app.kubernetes.io/instance=my-gzctf
```

## 组件说明

本 Chart 部署以下组件：

- **GZCTF 应用**：CTF 平台主程序
- **PostgreSQL**：用于存储 CTF 数据的数据库
- **Garnet**：兼容 Redis 的缓存，用于会话管理

每个组件都可以独立配置，或禁用后使用外部服务。

## 支持

如有问题或疑问：
- GZCTF 项目：https://github.com/GZTimeWalker/GZCTF
- Chart 问题：请在您的仓库中报告
