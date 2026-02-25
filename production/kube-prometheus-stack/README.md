# kube-prometheus-stack

本命名空间部署了完整的可观测性栈，包括 Prometheus、Grafana、Loki、Tempo 和 Mimir。

## Mimir

### 概念模型 (Concept Model)

#### 为什么需要 Mimir？

Prometheus 本身是一个优秀的指标采集和告警系统，但它有以下局限性：

1. **本地存储限制**：Prometheus 设计为短期存储，数据保留时间有限
2. **单体架构**：无法水平扩展以应对大规模指标数据
3. **无高可用保证**：单实例部署存在单点故障风险
4. **缺乏长期数据保留**：不适合存储数月甚至数年的历史数据

Mimir 解决了这些问题，它是一个**分布式、高可用、长期存储的 Prometheus 兼容后端**。

#### 架构概览

```
┌─────────────────┐
│   Prometheus    │
│   (采集+告警)    │
└────────┬────────┘
         │ remote_write
         ▼
┌──────────────────────────────────────────────────────────┐
│                     Mimir Gateway                         │
│              (API 入口、认证、路由)                       │
└────────────────────┬─────────────────────────────────────┘
                     │
         ┌───────────┴───────────┐
         ▼                       ▼
┌─────────────────┐    ┌─────────────────┐
│   Distributor   │    │  Query Frontend │
│   (数据分发)     │    │   (查询前端)    │
└────────┬────────┘    └────────┬────────┘
         │                      │
         ▼                      ▼
┌─────────────────┐    ┌─────────────────┐
│    Ingester     │    │    Querier      │
│  (实时接收+内存) │    │   (查询执行)    │
└────────┬────────┘    └────────┬────────┘
         │                      │
         └──────────┬───────────┘
                    ▼
         ┌─────────────────┐
         │ 对象存储 (Ceph) │
         │  (长期持久化)    │
         └─────────────────┘
```

#### 核心组件

| 组件 | 作用 | 本地存储需求 |
|------|------|-------------|
| **Gateway** | API 入口，路由读写请求 | 无 |
| **Distributor** | 接收写入请求，复制到多个 Ingester | 无 |
| **Ingester** | 实时接收数据，维护内存中的 TSDB，定期刷盘到对象存储 | **需要大空间** (我们配置 50Gi) |
| **Querier** | 执行查询，从 Ingester（实时数据）和 Store Gateway（历史数据）获取数据 | 无 |
| **Query Frontend** | 查询优化、缓存、分片 | 无 |
| **Store Gateway** | 从对象存储读取历史数据块 | 需要缓存空间 (我们配置 50Gi) |
| **Compactor** | 合并、压缩、清理过期数据块 | 需要工作空间 (我们配置 50Gi) |
| **Ruler** | 评估录制和告警规则 | 无 |
| **Alertmanager** | 处理告警通知 | 小空间 (我们配置 1Gi) |

#### 数据流向

##### 写入路径

```
1. Prometheus 通过 remote_write 协议发送指标到 Mimir Gateway
2. Gateway 转发给 Distributor
3. Distributor 复制数据到多个 Ingester（跨可用区保证高可用）
4. Ingester 将数据写入 WAL（Write-Ahead Log）并保存在内存中
5. 定期（head_compaction_interval: 15分钟）将内存数据 compact 成块
6. 定期（ship-interval: 默认1分钟）将块 upload 到对象存储
7. 本地块保留（retention-period: 默认13小时）后删除
```

##### 查询路径

```
1. Grafana 查询发送到 Query Frontend
2. Query Frontend 优化查询（分片、缓存等）
3. 分发到多个 Querier
4. Querier 同时查询：
   - Ingester：获取最近未刷盘的实时数据
   - Store Gateway：从对象存储获取历史数据
5. 合并结果返回给 Grafana
```

#### 关键配置说明

##### 存储配置

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `ingester.persistentVolume.size` | 50Gi | Ingester 本地存储大小，用于 WAL 和等待上传的块 |
| `store_gateway.persistentVolume.size` | 50Gi | Store Gateway 缓存空间 |
| `compactor.persistentVolume.size` | 50Gi | Compactor 工作空间 |
| `blocks_storage.tsdb.dir` | `/data/tsdb` | Ingester 本地 TSDB 目录 |
| `blocks_storage.backend` | s3 | 使用 Ceph RGW 作为对象存储（S3 兼容 API） |

##### 数据保留

| 配置项 | 值 | 说明 |
|--------|-----|------|
| `compactor_blocks_retention_period` | 168h (7天) | **对象存储**中数据保留时间，超过会被 Compactor 删除 |
| `blocks_storage.tsdb.retention-period` | (默认 13h) | **Ingester 本地**块保留时间 |

**关于 `compactor_blocks_retention_period` 的澄清**：
- 这个配置作用于**对象存储**中的数据，不是 Compactor 本地 PVC！
- 工作原理：
  1. Compactor 扫描对象存储中的块索引
  2. 检查每个块的 `MaxTime`（块中最新样本的时间戳）
  3. 如果 `MaxTime` 早于 `当前时间 - 保留期`，则标记该块删除
  4. 等待 `deletion_delay`（默认 2 小时）后真正删除
- Compactor 本地 PVC 仅用于**临时工作空间**（解压、compaction 等），不长期存储数据

##### Ingester 本地磁盘管理

**重要：Ingester 的本地磁盘不是长期存储！**

- **作用**：临时缓存，用于：
  - WAL（Write-Ahead Log）：保证数据不丢
  - 内存数据的临时落地
  - 等待上传到对象存储的块
- **数据会被自动清理**：
  - 块上传到对象存储后，本地保留 13 小时（默认）
  - 超过保留期的本地块会被删除
- **磁盘满的原因**：
  - PVC 配置太小（之前是 2Gi，已修复为 50Gi）
  - 上传到对象存储失败（但我们的 Ceph RGW 正常）

##### Ingest Storage 架构（实验性）

当前配置：
```yaml
ingest_storage:
  enabled: false
```

**说明**：
- 我们使用的是 **Classic 架构**（最稳定）
- Ingest Storage 是下一代架构，使用 Kafka 解耦读写路径
- 需要生产级 Kafka 集群，当前不启用

#### Grafana 数据源配置

| 数据源 | 地址 | 是否默认 | 用途 |
|--------|------|---------|------|
| Mimir | `http://mimir-gateway:80/prometheus` | ✓ **是** | 主要查询，包含所有历史数据 |
| Prometheus (本地) | - | 否 | 仅用于调试和短期数据 |

**为什么默认使用 Mimir？**
- 数据完整性：包含所有历史数据
- 查询性能：针对大规模查询优化
- 高可用：分布式架构更可靠

#### 高可用设计

- **Ingester**：3 副本，跨 3 个可用区（zone-a, zone-b, zone-c）
- **数据复制**：Distributor 写入时复制到多个 zone
- **Querier**：多副本，可以水平扩展
- **对象存储**：使用 Ceph RGW，数据持久化

#### 与 Prometheus 的关系

| 组件 | 职责 |
|------|------|
| **Prometheus** | 指标采集、告警规则评估（低延迟） |
| **Mimir** | 长期存储、大规模查询、高可用 |

Prometheus 通过 `remote_write` 实时发送数据给 Mimir，两者是**互补**关系，不是替代关系。
