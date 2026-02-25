# FreeIPA 数据备份与恢复指导

> **重要警告**：本文档基于 FreeIPA 官方源码编写，适用于 FreeIPA 4.x 版本。在执行任何备份或恢复操作前，请务必在测试环境验证。

## 目录

1. [概述](#概述)
2. [备份类型](#备份类型)
3. [备份操作](#备份操作)
4. [恢复操作](#恢复操作)
5. [Kubernetes 环境注意事项](#kubernetes 环境注意事项)
6. [故障排查](#故障排查)
7. [最佳实践](#最佳实践)

---

## 概述

FreeIPA 提供两种备份方式：

- **完整备份 (Full Backup)**：备份所有 IPA 配置文件、证书、密钥和目录服务器数据
- **数据备份 (Data-only Backup)**：仅备份 LDAP 目录数据，不包括配置文件

### 备份内容

#### 完整备份包括：

| 类别 | 内容 |
|------|------|
| **目录服务** | 389-DS 配置、LDIF 数据、changelog |
| **证书系统** | Dogtag PKI、CA 证书、KRA 数据 |
| **Kerberos** | KDC 配置、keytab 文件 |
| **DNS** | BIND 配置、DNSSEC 密钥、区域文件 |
| **HTTP 服务** | Apache 配置、SSL 证书 |
| **其他** | SSSD、Custody、NTP、AD Trust 配置 |

#### 数据备份包括：

- `userRoot` 后端 LDIF（用户、组、策略数据）
- `ipaca` 后端 LDIF（证书数据，如已安装 CA）
- 数据库归档文件

### 重要限制

1. **主机绑定**：备份只能恢复到**原始主机**（相同 FQDN）
2. **版本匹配**：备份只能恢复到**相同 IPA 版本**
3. **加密**：支持使用 GPG 加密备份（需要 root 用户的 GPG 密钥）

---

## 备份类型

### 备份命名约定

| 类型 | 目录命名格式 | 用途 |
|------|-------------|------|
| 完整备份 | `ipa-full-YYYY-MM-DD-HH-MM-SS` | 灾难恢复、系统迁移 |
| 数据备份 | `ipa-data-YYYY-MM-DD-HH-MM-SS` | 数据保护、定期备份 |

### 备份类型对比

| 特性 | 完整备份 | 数据备份 |
|------|---------|---------|
| 配置文件 | ✓ | ✗ |
| LDAP 数据 | ✓ | ✓ |
| 证书和密钥 | ✓ | ✗ |
| 日志文件 | 可选 | ✗ |
| 在线备份 | ✗ | 支持 (--online) |
| 停机时间 | 较长 | 较短 |
| 备份大小 | 大 (数 GB) | 小 (数百 MB) |

---

## 备份操作

### 前置条件

1. 确保在具有所有集群角色的 IPA 服务器上执行备份
2. 检查可用磁盘空间（至少需要 10GB 可用空间）
3. 确保具有 root 权限

### 执行完整备份

```bash
# 基本完整备份
ipa-backup

# 包含日志文件的完整备份
ipa-backup --logs

# 加密备份（需要配置 GPG）
export GNUPGHOME=/root/.gnupg
ipa-backup --gpg

# 跳过角色检查（不推荐）
ipa-backup --disable-role-check
```

### 执行数据备份

```bash
# 离线数据备份（默认，需要停止 IPA 服务）
ipa-backup --data

# 在线数据备份（服务不停机）
ipa-backup --data --online

# 加密在线数据备份
ipa-backup --data --online --gpg
```

### 备份位置

备份存储在 `/var/lib/ipa/backup/` 目录：

```bash
# 查看备份列表
ls -la /var/lib/ipa/backup/

# 示例输出：
# drwxr-x--- 2 root root 4096 Feb 24 14:00 ipa-full-2026-02-24-14-00-00
# drwxr-x--- 2 root root 4096 Feb 24 14:30 ipa-data-2026-02-24-14-30-00
```

### 备份元文件

每个备份目录包含 `header` 文件，记录备份信息：

```bash
cat /var/lib/ipa/backup/ipa-full-*/header

# 示例内容：
# IPA backup type: FULL
# IPA version: 4.12.2
# Backup version: 3.0
# Hostname: ipa-01.clusters.zjusct.io
# Date: 2026-02-24T14:00:00
# Services: CA, DNS, KRA, ADTRUST
```

### 备份脚本示例

```bash
#!/bin/bash
# /usr/local/bin/ipa-daily-backup.sh

set -e

BACKUP_TYPE="${1:-data}"
LOG_FILE="/var/log/ipa-backup.log"
DATE=$(date +%Y-%m-%d_%H-%M-%S)

echo "[$DATE] Starting $BACKUP_TYPE backup" >> "$LOG_FILE"

if [ "$BACKUP_TYPE" = "full" ]; then
    ipa-backup --logs >> "$LOG_FILE" 2>&1
else
    ipa-backup --data --online >> "$LOG_FILE" 2>&1
fi

# 保留最近 7 天的备份
find /var/lib/ipa/backup -type d -mtime +7 -exec rm -rf {} \;

echo "[$(date +%Y-%m-%d_%H-%M-%S)] Backup completed" >> "$LOG_FILE"
```

---

## 恢复操作

### 恢复前准备

#### 1. 禁用其他副本的复制

**在恢复前必须在所有其他 IPA 服务器上执行：**

```bash
# 查看复制拓扑
ipa-replica-manage list

# 禁用复制（在其他所有 master 上执行）
ipa-replica-manage disconnect <要恢复的服务器>

# 如果是 CA 集群，还需要禁用 CA 复制
ipa-csreplica-manage disconnect <要恢复的服务器>
```

#### 2. 获取 Directory Manager 密码

```bash
# 密码通常存储在
cat /etc/dirsrv/passwd
# 或从 SealedSecret 获取
kubectl -n freeipa get secret freeipa-admin-secrets -o jsonpath='{.data.admin-password}' | base64 -d
```

### 执行完整恢复

**警告：完整恢复将覆盖系统配置文件**

```bash
# 停止 IPA 服务
ipactl stop

# 执行恢复（需要指定 DM 密码）
ipa-restore /var/lib/ipa/backup/ipa-full-2026-02-24-14-00-00 -p <DM_PASSWORD>

# 或者不指定密码（交互式提示）
ipa-restore /var/lib/ipa/backup/ipa-full-2026-02-24-14-00-00

# 恢复日志文件（如果备份中包含）
ipa-restore /var/lib/ipa/backup/ipa-full-2026-02-24-14-00-00 --no-logs
```

### 执行数据恢复

```bash
# 离线数据恢复（推荐）
ipa-restore --data /var/lib/ipa/backup/ipa-data-2026-02-24-14-30-00 -p <DM_PASSWORD>

# 在线数据恢复（服务不停机）
ipa-restore --data --online /var/lib/ipa/backup/ipa-data-2026-02-24-14-30-00 -p <DM_PASSWORD>

# 恢复特定实例
ipa-restore --data --instance CLUSTERS-ZJUSCT-IO /var/lib/ipa/backup/ipa-data-2026-02-24-14-30-00

# 恢复特定后端
ipa-restore --data --backend userRoot /var/lib/ipa/backup/ipa-data-2026-02-24-14-30-00
```

### 恢复后操作

#### 1. 重新启用复制

```bash
# 在恢复的服务器上确认服务状态
ipactl status

# 在其他 master 上重新启用复制
ipa-replica-manage connect <恢复的服务器>

# 重新初始化复制
ipa-replica-manage re-initialize --from=<恢复的服务器>

# 如果是 CA 集群
ipa-csreplica-manage connect <恢复的服务器>
ipa-csreplica-manage re-initialize --from=<恢复的服务器>
```

#### 2. 验证恢复

```bash
# 验证 LDAP 数据
ldapsearch -Y GSSAPI -H ldapi:/// -b "cn=accounts,dc=clusters,dc=zjusct,dc=io" "(objectClass=*)" | head -50

# 验证 Kerberos
kinit admin
ipa user-show admin

# 验证 DNS
ipa dnszone-show clusters.zjusct.io

# 验证证书
ipa cert-find | head -20

# 验证服务状态
ipactl status
```

### Kubernetes 环境恢复流程

```bash
# 1. 进入 IPA Pod
kubectl -n freeipa exec -it pod/ipa-01-0 -- bash

# 2. 在 Pod 内执行备份
ipa-backup --data --online

# 3. 查看备份
ls -la /var/lib/ipa/backup/

# 4. 恢复操作
# 停止服务
ipactl stop

# 执行恢复
ipa-restore --data /var/lib/ipa/backup/ipa-data-2026-02-24-14-30-00 -p <DM_PASSWORD>

# 5. 重启服务
ipactl start
```

---

## Kubernetes 环境注意事项

### Pod 持久化存储

确保以下目录挂载到持久化存储：

```yaml
# StatefulSet 卷配置示例
volumeClaimTemplates:
- metadata:
    name: data
  spec:
    accessModes: ["ReadWriteOnce"]
    resources:
      requests:
        storage: 50Gi
    # 确保以下目录持久化：
    # /data - IPA 主数据目录
    # /var/lib/ipa/backup - 备份目录
    # /var/lib/dirsrv - 目录服务数据
    # /var/lib/pki - PKI 数据
```

### 备份自动化

```yaml
# CronJob 示例 - 每日数据备份
apiVersion: batch/v1
kind: CronJob
metadata:
  name: ipa-backup
  namespace: freeipa
spec:
  schedule: "0 2 * * *"  # 每天凌晨 2 点
  jobTemplate:
    spec:
      template:
        spec:
          containers:
          - name: backup
            image: harbor.clusters.zjusct.io/freeipa/freeipa-server:latest
            command:
            - /bin/bash
            - -c
            - |
              ipa-backup --data --online
              # 备份外部存储（可选）
              cp -r /var/lib/ipa/backup /backup/external/
            volumeMounts:
            - name: data
              mountPath: /data
            - name: backup
              mountPath: /backup/external
          restartPolicy: OnFailure
          volumes:
          - name: data
            persistentVolumeClaim:
              claimName: freeipa-data
          - name: backup
            persistentVolumeClaim:
              claimName: freeipa-backup
```

### 灾难恢复场景

#### 场景 1：单节点故障

```bash
# 如果有多个 IPA 副本，从其他副本恢复服务
# 1. 在其他副本上验证服务正常
kubectl -n freeipa exec pod/ipa-02-0 -- ipactl status

# 2. 修复故障节点或部署新节点
# 3. 从现有副本重新初始化
```

#### 场景 2：数据损坏（如 DNS 区域丢失）

```bash
# 1. 找到最近的可用备份
kubectl -n freeipa exec pod/ipa-01-0 -- ls -la /var/lib/ipa/backup/

# 2. 执行数据恢复（不停机）
kubectl -n freeipa exec pod/ipa-01-0 -- \
  ipa-restore --data --online /var/lib/ipa/backup/ipa-data-2026-02-24-14-30-00 -p <DM_PASSWORD>

# 3. 验证数据
kubectl -n freeipa exec pod/ipa-01-0 -- ipa dnszone-show clusters.zjusct.io
```

#### 场景 3：完全灾难恢复

```bash
# 1. 从备份恢复配置和数据
ipa-restore /var/lib/ipa/backup/ipa-full-DATE -p <DM_PASSWORD>

# 2. 重新建立复制拓扑
# 在所有其他 master 上：
ipa-replica-manage connect <恢复的服务器>
ipa-replica-manage re-initialize --from=<恢复的服务器>

# 3. 验证所有服务
for svc in directory krb5kdc http pki-tomcat dns; do
  systemctl status $svc
done
```

---

## 故障排查

### 常见问题

#### 1. 备份失败：角色检查错误

**错误信息：**
```
Error: Local roles DNS do not match globally used roles DNS, CA.
```

**解决方案：**
```bash
# 在具有所有角色的服务器上执行备份
# 或临时禁用角色检查（不推荐）
ipa-backup --disable-role-check
```

#### 2. 恢复失败：磁盘空间不足

**错误信息：**
```
db2ldif failed. Check file systems' free space.
```

**解决方案：**
```bash
# 检查磁盘空间
df -h /var/lib

# 清理旧备份
find /var/lib/ipa/backup -type d -mtime +30 -exec rm -rf {} \;

# 或使用外部存储
mkdir -p /external/backup
ipa-backup --data
mv /var/lib/ipa/backup/ipa-data-* /external/backup/
```

#### 3. 恢复失败：版本不匹配

**错误信息：**
```
Cannot restore backup: IPA version mismatch
```

**解决方案：**
- 备份和恢复必须在相同 IPA 版本上执行
- 升级 IPA 后再恢复，或找到对应版本的备份

#### 4. 复制冲突

**症状：** 恢复后数据被其他副本覆盖

**解决方案：**
```bash
# 1. 立即断开所有复制连接
ipa-replica-manage list
ipa-replica-manage disconnect <所有其他服务器>

# 2. 执行恢复

# 3. 逐个重新连接并重新初始化
ipa-replica-manage connect <服务器 1>
ipa-replica-manage re-initialize --from=<恢复的服务器>
```

### 日志文件位置

| 日志 | 路径 |
|------|------|
| 备份日志 | `/var/log/ipabackup.log` |
| 恢复日志 | `/var/log/iparestore.log` |
| 安装日志 | `/var/log/ipaserver-install.log` |
| 目录服务日志 | `/var/log/dirsrv/slapd-*/` |
| HTTP 日志 | `/var/log/httpd/` |

---

## 最佳实践

### 备份策略

| 场景 | 频率 | 类型 | 保留期 |
|------|------|------|--------|
| 生产环境 | 每日 | 数据备份（在线） | 30 天 |
| 生产环境 | 每周 | 完整备份 | 12 周 |
| 变更前 | 手动 | 数据备份 | 永久 |
| 版本升级前 | 手动 | 完整备份 | 永久 |

### 备份验证

定期验证备份可用性：

```bash
# 1. 在测试环境恢复备份
# 2. 运行验证检查
ipa user-show admin
ipa dnszone-show clusters.zjusct.io
ipa cert-find

# 3. 验证 Kerberos 认证
echo "test_password" | kinit admin

# 4. 验证复制（如果有多个副本）
ipa-replica-manage list-ruv
```

### 安全建议

1. **加密备份**：使用 GPG 加密敏感备份
   ```bash
   # 生成 GPG 密钥
   gpg2 --gen-key

   # 加密备份
   ipa-backup --gpg
   ```

2. **离线存储**：将备份复制到外部存储或对象存储
   ```bash
   # 备份到 S3 兼容存储
   mc cp -r /var/lib/ipa/backup s3/backups/ipa/

   # 或复制到 NFS
   rsync -av /var/lib/ipa/backup/ /mnt/nfs/ipa-backup/
   ```

3. **访问控制**：限制备份文件访问
   ```bash
   chmod 750 /var/lib/ipa/backup/
   chown root:dirsrv /var/lib/ipa/backup/
   ```

### 监控和告警

```bash
# 检查备份是否最新
find /var/lib/ipa/backup -type d -mtime +1

# 监控脚本
#!/bin/bash
LATEST_BACKUP=$(ls -td /var/lib/ipa/backup/ipa-data-* | head -1)
if [ -z "$LATEST_BACKUP" ] || [ $(find "$LATEST_BACKUP" -mtime +1 | wc -l) -gt 0 ]; then
    echo "CRITICAL: No recent IPA backup found" | mail -s "IPA Backup Alert" admin@example.com
fi
```

---

## 参考文档

- [FreeIPA 官方文档 - Backup and Restore](https://freeipa.readthedocs.io/en/latest/adminguide/backup-and-restore.html)
- [389 Directory Server - Backup and Restore](https://access.redhat.com/documentation/en-us/red_hat_directory_server/11/html/administration_guide/backup_and_restore)
- [Red Hat IPA 4.x 管理指南](https://access.redhat.com/documentation/en-us/red_hat_enterprise_linux/8/html/configuring_and_managing_identity_management/)

---

## 附录：快速参考命令

```bash
# ===== 备份命令 =====
ipa-backup                           # 完整备份
ipa-backup --data                    # 数据备份
ipa-backup --data --online           # 在线数据备份
ipa-backup --gpg                     # 加密备份
ipa-backup --logs                    # 包含日志

# ===== 恢复命令 =====
ipa-restore /path/to/backup          # 完整恢复
ipa-restore --data /path/to/backup   # 数据恢复
ipa-restore --data --online          # 在线数据恢复
ipa-restore -p PASSWORD              # 指定 DM 密码

# ===== 复制管理 =====
ipa-replica-manage list              # 列出复制拓扑
ipa-replica-manage disconnect HOST   # 断开复制
ipa-replica-manage connect HOST      # 连接复制
ipa-replica-manage re-initialize     # 重新初始化

# ===== 验证命令 =====
ipactl status                        # 服务状态
ipa dnszone-show ZONE                # DNS 区域
ipa user-show USER                   # 用户数据
ldapsearch -Y GSSAPI ...             # LDAP 查询
```
