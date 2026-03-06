## CephFS `balance_automate` 深度源码分析：为什么开启后延迟从 2ms 飙升到 200ms+

### 一、整体架构概览

在 CephFS 多 MDS 架构中，元数据以**子树 (subtree)** 为单位分布在不同的 MDS rank 上。当只有一个 MDS 承担负载时（即使 `max_mds=3`），所有元数据操作在单节点完成，没有跨节点通信。

当开启 `balance_automate` 后，`MDBalancer` 模块会**主动地将子树迁移到其他 MDS rank 上**，这引入了多个层面的延迟来源。

---

### 二、不开启 `balance_automate` 时的工作方式

**关键代码**：

```c++ name=src/mds/MDBalancer.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDBalancer.cc#L277-L306
void MDBalancer::tick()
{
  bool balance_automate = mds->mdsmap->allows_balance_automate();
  time now = clock::now();

  if (bal_export_pin) {
    handle_export_pins();
  }

  // balance?
  if (balance_automate         // <--- 只有 balance_automate 为 true 才会进入
      && mds->get_nodeid() == 0
      && mds->is_active()
      && bal_interval > 0
      && chrono::duration_cast<chrono::seconds>(now - last_heartbeat).count() >= bal_interval
      && (num_bal_times || (bal_max_until >= 0 && mds->get_uptime().count() > bal_max_until))) {
    last_heartbeat = now;
    send_heartbeat();
    num_bal_times--;
  }
}
```

**不开启时**（默认行为）：
- `balance_automate = false`，`tick()` 只处理 `export_pin`（手动 pin），**不会发送 heartbeat，不会触发 rebalance**
- 所有元数据保持在 rank 0 上
- 客户端的所有请求直接发送到 rank 0，请求路径为：`client → MDS rank 0 → 处理 → 返回`
- **单次 RTT，无跨 MDS 通信，延迟 ~2ms 完全合理**

---

### 三、开启 `balance_automate` 后的完整工作链路

开启后，以下机制被激活：

#### 3.1 Heartbeat 与负载采集

rank 0 的 MDS 每 `mds_bal_interval`（默认 **10秒**）发送一次 heartbeat，收集所有 MDS 的负载信息：

```c++ name=src/mds/MDBalancer.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDBalancer.cc#L546-L567
void MDBalancer::handle_heartbeat(const cref_t<MHeartbeat> &m)
{
  // ...
  mds_import_map[who] = m->get_import_map();
  if (mds_load.size() == cluster_size) {
    // let's go! -- 当收齐所有 MDS 的负载信息后触发 rebalance
  }
}
```

#### 3.2 负载计算（bal_mode=0，默认 Hybrid 模式）

```c++ name=src/mds/MDBalancer.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDBalancer.cc#L328-L339
double mds_load_t::mds_load(int64_t bal_mode) const
{
  switch(bal_mode) {
  case 0:   // Hybrid (默认)
    return
      .8 * auth.meta_load() +
      .2 * all.meta_load() +
      req_rate +
      10.0 * queue_len;
  case 1:
    return req_rate + 10.0*queue_len;
  case 2:
    return cpu_load_avg;
  }
}
```

#### 3.3 计算迁移目标（prep_rebalance）

```c++ name=src/mds/MDBalancer.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDBalancer.cc#L792-L816
void MDBalancer::prep_rebalance(int beat)
{
  // ...
  // target_load = 总负载 / MDS 数量 (每个 MDS 的目标负载)
  target_load = total_load / (double)mds->mdsmap->get_num_mdss_in_rank_mask_bitset();

  // 如果当前 MDS 负载高于 target，就需要 export 子树到其他 MDS
  // ...
}
```

#### 3.4 实际迁移（try_rebalance → export_dir_nicely → Migrator）

```c++ name=src/mds/MDBalancer.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDBalancer.cc#L1124-L1143
void MDBalancer::try_rebalance(balance_state_t& state)
{
  // ...
  for (const auto& dir : exports) {
    mds->mdcache->migrator->export_dir_nicely(dir, target);  // 触发子树迁移
  }
}
```

---

### 四、延迟飙升的 5 大核心原因

#### 原因 1：子树迁移过程中的 Freeze（冻结）— 阻塞所有请求

这是**最主要的延迟来源**。迁移子树时，Migrator 必须 freeze（冻结）整个子树：

```c++ name=src/mds/Migrator.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/Migrator.cc#L1286-L1300
void Migrator::dispatch_export_dir(const MDRequestRef& mdr, int count)
{
  // ...
  // start the freeze, but hold it up with an auth_pin.
  dir->freeze_tree();
  ceph_assert(dir->is_freezing_tree());
  dir->add_waiter(CDir::WAIT_FROZEN, new C_MDC_ExportFreeze(this, dir, it->second.tid));
}
```

**冻结的影响**：
- `freeze_tree()` 会遍历整个子树，标记所有 dirfrag 为 `freezing` 状态
- 在 freeze 期间，该子树下的**所有客户端请求都会被阻塞**（等待 WAIT_FROZEN）
- freeze 需要等待所有现有的 `auth_pin` 被释放后才能完成
- 如果有 auth_pin 交叉死锁风险，还有超时取消机制（`mds_freeze_tree_timeout`），但取消后重试又引入更多延迟

```c++ name=src/mds/CDir.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/CDir.cc#L3559-L3577
bool CDir::freeze_tree()
{
  // 遍历子树标记 freezing，收集 auth_pins
  freeze_tree_state = std::make_shared<freeze_tree_state_t>(this);
  freeze_tree_state->auth_pins += get_auth_pins() + get_dir_auth_pins();
  if (!lock_caches_with_auth_pins.empty())
    mdcache->mds->locker->invalidate_lock_caches(this);
  // ...
}
```

#### 原因 2：Client 请求转发（Forward）— 额外 RTT

当子树被迁移到其他 MDS 后，客户端最初并不知道元数据在哪个 MDS 上。客户端仍然会把请求发到老的 MDS，然后被 forward（转发）：

```c++ name=src/mds/MDSRank.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDSRank.cc#L1502-L1521
void MDSRank::forward_message_mds(const MDRequestRef& mdr, mds_rank_t mds)
{
  // NEW: always make the client resend!
  bool client_must_resend = true;

  // 告诉客户端去哪个 MDS
  auto f = make_message<MClientRequestForward>(
    m->get_tid(), mds, m->get_num_fwd()+1, client_must_resend);
  send_message_client(f, session);
}
```

**关键发现**：`client_must_resend = true` — MDS **不会代替客户端转发请求**，而是告诉客户端"你去找 MDS.X 重新发"。

这意味着一次操作变成了：
```
client → MDS.0 (发现不是 auth) → 返回 Forward 消息 → client → MDS.X → 处理 → 返回
```

**额外增加了 2 次网络 RTT**。如果网络延迟是 0.5ms，这就增加了 ~2ms。

#### 原因 3：Capability (Caps) 撤回和重新授予 — 最大隐形杀手

这是最容易被忽略但**影响最大**的因素。当子树迁移时，相关 inode 的 caps（capability）需要被**撤回 (revoke)** 后在新 MDS 上**重新授予 (grant)**：

```c++ name=src/mds/Locker.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/Locker.cc#L2657-L2692
int Locker::issue_caps(CInode *in, Capability *only_cap)
{
  // ...
  int op = (before & ~after) ? CEPH_CAP_OP_REVOKE : CEPH_CAP_OP_GRANT;
  if (op == CEPH_CAP_OP_REVOKE) {
    revoking_caps.push_back(&cap->item_revoking_caps);
    cap->set_last_revoke_stamp(ceph_clock_now());
  }
  // 发送 MClientCaps 消息给客户端
  auto m = make_message<MClientCaps>(op, in->ino(), ...);
  mds->send_message_client_counted(m, cap->get_session());
}
```

**为什么 caps revoke 如此耗时？**

1. **Revoke 需要客户端确认**：MDS 发出 revoke，必须等客户端 flush dirty data 后返回 ack
2. **客户端可能持有大量 caps**：如果客户端缓存了很多文件的 caps（读写权限），每个都需要 revoke
3. **脏数据 flush**：如果客户端有未写入的数据（dirty caps），必须先将数据写入 OSD 后才能释放 caps。这可能涉及多次 OSD 写入，延迟 10-100ms+
4. **导出前的 session flush**：

```c++ name=src/mds/Migrator.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/Migrator.cc#L1554-L1574
void Migrator::export_frozen(CDir *dir, uint64_t tid)
{
  // ...
  // make sure any new instantiations of caps are flushed out
  get_export_client_set(dir, it->second.export_client_set);
  MDSGatherBuilder gather(g_ceph_context);
  mds->server->flush_client_sessions(it->second.export_client_set, gather);
  // ...
}
```

#### 原因 4：缓存失效和冷启动

迁移到新 MDS 后：
- 新 MDS 的 **metadata cache 是冷的**：目录/inode 信息需要从 RADOS 重新加载
- 旧 MDS 上的 **dentry lease（目录项租约）被清除**
- 客户端需要重新建立到新 MDS 的 session
- 客户端需要重新 lookup 路径，获取新的 caps

每次 cache miss 都意味着从 RADOS 读取元数据，增加 ~5-20ms 延迟。

#### 原因 5：持续的 Balancer 震荡（Thrashing）

balancer 每 10 秒运行一次（`mds_bal_interval = 10`），如果负载模型不准确或波动较大：
- 子树可能在 MDS 之间**反复迁移**
- 每次迁移都重复上述所有开销
- `MIN_OFFLOAD = 10`, `MIN_REEXPORT = 5` 等阈值较低，可能导致频繁的小规模迁移

```c++ name=src/mds/MDBalancer.cc url=https://github.com/ceph/ceph/blob/21568a69138bf5fa3f23adc5d0d93feea6a8335e/src/mds/MDBalancer.cc#L60-L62
#define MIN_LOAD    50   //  ??
#define MIN_REEXPORT 5   // will automatically reexport
#define MIN_OFFLOAD 10   // point at which i stop trying, close enough
```

---

### 五、延迟时间线对比

| 阶段 | 不开启 balance_automate | 开启 balance_automate |
|------|----------------------|---------------------|
| 请求路由 | 直接到 MDS.0 (~0.5ms) | 可能需要 forward (~2ms 额外) |
| 元数据查找 | 热缓存命中 (~0.1ms) | 可能 cache miss + RADOS fetch (~10-20ms) |
| 锁获取 | 本地锁 (~0.1ms) | 跨 MDS 锁协调 (~5-10ms) |
| 正常处理 | ~1ms | ~1ms |
| Caps 操作 | 本地 grant (~0.1ms) | revoke+re-grant (~10-50ms) |
| Freeze 期间等待 | 无 | 可能 50-200ms+ |
| **总延迟** | **~2ms** | **50-200ms+** |

---

### 六、优化方案

#### 方案 1：使用静态 Export Pin 替代动态 Balancer（推荐 ✅）

**这是目前 CephFS 社区推荐的做法**。文档也明确说明 balancer "sometimes inefficient or slow"。

```bash
# 关闭动态 balancer
ceph fs set <fs_name> balance_automate false

# 使用 export pin 手动分配子树到不同 MDS
setfattr -n ceph.dir.pin -v 0 /cephfs/dir_a
setfattr -n ceph.dir.pin -v 1 /cephfs/dir_b
setfattr -n ceph.dir.pin -v 2 /cephfs/dir_c
```

**优势**：
- 子树一旦固定不会迁移，无 freeze 开销
- 客户端快速学习目标 MDS，不需要 forward
- Cache 保持温热

#### 方案 2：使用 Ephemeral Distributed Pin（推荐 ✅）

适合像 `/home` 这样的大目录：

```bash
ceph fs set <fs_name> balance_automate false
setfattr -n ceph.dir.pin.distributed -v 1 /cephfs/home
```

这会将目录的 fragment 通过一致性哈希分布到各 MDS，**无动态迁移开销**。

#### 方案 3：如果必须使用 balance_automate，调整参数

```bash
# 增大 balancer 间隔，减少迁移频率
ceph config set mds mds_bal_interval 60       # 默认 10秒，改为 60秒

# 使用 bal_rank_mask 限制 balancer 只在部分 rank 上工作
ceph fs set <fs_name> bal_rank_mask 0x3        # 只在 rank 0 和 1 上 balance

# 增大 idle threshold，避免来回弹跳
ceph config set mds mds_bal_idle_threshold 10

# 增大 min_rebalance，只有显著不均时才触发
ceph config set mds mds_bal_min_rebalance 0.5  # 默认 0.1

# 增加 overload_epochs，避免短暂负载波动触发迁移
ceph config set mds mds_bal_overload_epochs 5  # 默认 2
```

#### 方案 4：混合方案（推荐用于生产环境 ✅）

```bash
# 高 IO 路径用静态 pin
setfattr -n ceph.dir.pin -v 0 /cephfs/hot_dir_a
setfattr -n ceph.dir.pin -v 1 /cephfs/hot_dir_b

# 冷路径允许动态 balance，但只在特定 rank 上
ceph fs set <fs_name> balance_automate true
ceph fs set <fs_name> bal_rank_mask 0x4        # 只有 rank 2 参与 balance
```

这也是 `bal_rank_mask` 设计的初衷——隔离静态 pin 和动态 balance 的 MDS rank。

---

### 七、总结

| 因素 | 影响程度 | 说明 |
|------|---------|------|
| **Subtree freeze** | ⭐⭐⭐⭐⭐ | 迁移期间整个子树请求被阻塞，这是最大延迟源 |
| **Caps revoke/flush** | ⭐⭐⭐⭐⭐ | 客户端脏数据必须 flush 到 OSD 后才能释放 caps |
| **Cache cold start** | ⭐⭐⭐⭐ | 新 MDS 需要从 RADOS 加载元数据 |
| **Request forward** | ⭐⭐⭐ | 客户端被要求重新发送请求到新 MDS (额外 2 RTT) |
| **Balancer thrashing** | ⭐⭐⭐ | 频繁迁移导致持续性能损害 |

**核心结论**：2ms → 200ms 的延迟上升完全符合预期。CephFS 动态 balancer 的设计本身就是以牺牲短期延迟换取长期均衡分布。但由于迁移代价极高（freeze + caps revoke + cache invalidation），在实际生产中，**静态 export pin + ephemeral pin 组合**是远优于动态 balancer 的方案。

> **注意**：以上代码搜索结果可能不完整。你可以在 [GitHub 代码搜索](https://github.com/search?q=repo%3Aceph%2Fceph+balance_automate&type=code)中查看更多相关代码。
