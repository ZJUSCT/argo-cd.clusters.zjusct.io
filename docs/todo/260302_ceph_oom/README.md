# Rook Ceph MDS OOM 问题

## 问题描述

集群 CephFS 使用量不断增长，MDS 内存占用突破默认值 4Gi 导致 OOM Kill。此时 MDS pod 会被调度重启，然后迅速增长到 OOM Kill，形成死循环。

MDS 的 resource 限制在 rook ceph helm chart 中定义，见 production/rook-ceph/values/rook-ceph-cluster-v1.19.1.yaml

```
      metadataServer:
        activeCount: 3
        activeStandby: true
        resources:
          limits:
            memory: "192Gi"
          requests:
            cpu: "1000m"
            memory: "96Gi"
        priorityClassName: system-cluster-critical
```

当时 MDS 陷入 OOM Kill 死循环时，即使我们更改此处的内存限制并应用，Rook Ceph Operator 因为逻辑问题未能成功更新 MDS Deployment 的内存限制，导致问题持续。当时的 Operator 日志如下：

```
2026-03-01T23:34:06.431054819+08:00 2026-03-01 15:34:06.430937 I | ceph-spec: resource "CephFilesystem": "rook-ceph/cephfs" spec has changed. diff=  v1.FilesystemSpec{
2026-03-01T23:34:06.431087935+08:00   	... // 3 identical fields
2026-03-01T23:34:06.431095052+08:00   	PreservePoolsOnDelete:      false,
2026-03-01T23:34:06.431101585+08:00   	PreserveFilesystemOnDelete: true,
2026-03-01T23:34:06.431106975+08:00   	MetadataServer: v1.MetadataServerSpec{
2026-03-01T23:34:06.431112209+08:00   		... // 3 identical fields
2026-03-01T23:34:06.431117612+08:00   		Annotations: nil,
2026-03-01T23:34:06.431122872+08:00   		Labels:      nil,
2026-03-01T23:34:06.431128479+08:00   		Resources: v1.ResourceRequirements{
2026-03-01T23:34:06.431134202+08:00 - 			Limits: v1.ResourceList{s"memory": {i: resource.int64Amount{value: 8589934592}, Format: "BinarySI"}},
2026-03-01T23:34:06.431139859+08:00 + 			Limits: v1.ResourceList{s"memory": {i: resource.int64Amount{value: 214748364800}, Format: "BinarySI"}},
2026-03-01T23:34:06.431163192+08:00   			Requests: v1.ResourceList{
2026-03-01T23:34:06.431167815+08:00   				s"cpu":    {i: {...}, Format: "DecimalSI"},
2026-03-01T23:34:06.431171945+08:00 - 				s"memory": {i: resource.int64Amount{value: 8589934592}, Format: "BinarySI"},
2026-03-01T23:34:06.431175725+08:00 + 				s"memory": {i: resource.int64Amount{value: 85899345920}, Format: "BinarySI"},
2026-03-01T23:34:06.431179485+08:00   			},
2026-03-01T23:34:06.431183382+08:00   			Claims: nil,
2026-03-01T23:34:06.431187159+08:00   		},
2026-03-01T23:34:06.431190962+08:00   		PriorityClassName: "system-cluster-critical",
2026-03-01T23:34:06.431195029+08:00   		LivenessProbe:     nil,
2026-03-01T23:34:06.431198769+08:00   		... // 3 identical fields
2026-03-01T23:34:06.431202429+08:00   	},
2026-03-01T23:34:06.431206192+08:00   	Mirroring:   nil,
2026-03-01T23:34:06.431209989+08:00   	StatusCheck: {},
2026-03-01T23:34:06.431213739+08:00   }
2026-03-01T23:34:06.438340247+08:00 2026-03-01 15:34:06.438214 I | ceph-spec: parsing mon endpoints: b=172.25.4.11:6789,c=172.25.4.61:6789,a=172.25.4.60:6789
2026-03-01T23:34:06.438382787+08:00 2026-03-01 15:34:06.438302 I | ceph-spec: detecting the ceph image version for image quay.io/ceph/ceph:v19.2.3...
2026-03-01T23:34:07.040574574+08:00 2026-03-01 15:34:07.040386 I | disruption: OSDs are up and PGs are clean. PG status: "all PGs in cluster are clean"
2026-03-01T23:34:07.488532437+08:00 2026-03-01 15:34:07.488379 I | disruption: successfully reconciled OSD PDB controller
2026-03-01T23:34:08.614638624+08:00 2026-03-01 15:34:08.614473 I | disruption: OSDs are up and PGs are clean. PG status: "all PGs in cluster are clean"
2026-03-01T23:34:09.125454544+08:00 2026-03-01 15:34:09.125259 I | disruption: successfully reconciled OSD PDB controller
2026-03-01T23:34:09.210419856+08:00 2026-03-01 15:34:09.210275 I | ceph-spec: detected ceph image version: "19.2.3-0 squid"
2026-03-01T23:34:12.252614975+08:00 2026-03-01 15:34:12.252392 I | file-controller: [rook-ceph/cephfs] start running mdses for filesystem "cephfs"
2026-03-01T23:34:12.827445553+08:00 2026-03-01 15:34:12.827254 I | cephclient: getting or creating ceph auth key "mds.cephfs-a"
2026-03-01T23:34:13.351784477+08:00 2026-03-01 15:34:13.351643 I | op-mds: [rook-ceph/cephfs] setting mds config flags
2026-03-01T23:34:13.351804667+08:00 2026-03-01 15:34:13.351677 I | op-config: setting option "mds_cache_memory_limit" (user "mds.cephfs-a") to the mon configuration database
2026-03-01T23:34:13.768721265+08:00 2026-03-01 15:34:13.768600 I | op-config: successfully set option "mds_cache_memory_limit" (user "mds.cephfs-a") to the mon configuration database
2026-03-01T23:34:13.768749691+08:00 2026-03-01 15:34:13.768624 I | op-config: setting option "mds_join_fs" (user "mds.cephfs-a") to the mon configuration database
2026-03-01T23:34:14.184181342+08:00 2026-03-01 15:34:14.184037 I | op-config: successfully set option "mds_join_fs" (user "mds.cephfs-a") to the mon configuration database
2026-03-01T23:34:14.194158448+08:00 2026-03-01 15:34:14.194023 I | op-mds: [rook-ceph/cephfs] deployment for mds "rook-ceph-mds-cephfs-a" already exists. updating if needed
2026-03-01T23:34:14.207040360+08:00 2026-03-01 15:34:14.206953 I | op-k8sutil: updating deployment "rook-ceph-mds-cephfs-a" after verifying it is safe to stop
2026-03-01T23:34:14.207065777+08:00 2026-03-01 15:34:14.206968 I | op-mon: [rook-ceph] checking if we can stop the deployment rook-ceph-mds-cephfs-a
2026-03-01T23:34:15.262233254+08:00 2026-03-01 15:34:15.262103 I | util: retrying after 15s, last error: deployment rook-ceph-mds-cephfs-a cannot be stopped. . Error EBUSY: one or more filesystems is currently degraded: exit status 16
2026-03-01T23:34:30.853658640+08:00 2026-03-01 15:34:30.853537 I | util: retrying after 15s, last error: deployment rook-ceph-mds-cephfs-a cannot be stopped. . Error EBUSY: one or more filesystems is currently degraded: exit status 16
2026-03-01T23:34:46.395710559+08:00 2026-03-01 15:34:46.395614 I | util: retrying after 15s, last error: deployment rook-ceph-mds-cephfs-a cannot be stopped. . Error EBUSY: one or more filesystems is currently degraded: exit status 16
```

可以看到，Rook Ceph Operator 在检测到 CephFilesystem 资源的 spec 发生变化后，尝试更新 MDS Deployment 的内存限制，但因为 CephFS 处于 degraded 状态无法停止 MDS Deployment，导致更新失败。Operator 会持续重试，但因为 CephFS 状态未恢复，更新始终无法成功。**即使我们手工删除了 ceph mds 的 deployment，operator 似乎仍然在报错 filesystem is currently degraded。**

我们在 GitHub 找到了相关 Issue：https://github.com/rook/rook/issues/16702。这个 Issue 是关于 MON 的，但现象、报错与我们的 MDS OOM 情况类似，我认为这揭示了 Rook Ceph Operator 资源更新逻辑中普遍的问题。

operator doesn't prioritize creating missing mon deployments over reconfiguring existing ones? #16702
Not planned
Not planned
operator doesn't prioritize creating missing mon deployments over reconfiguring existing ones?
#16702
@wrouesnel
Description
wrouesnel
opened on Nov 12, 2025 · edited by wrouesnel
Is this a bug report or feature request?

Bug Report
Deviation from expected behavior:

mon deployment is not recreated if another mon deployment needs updating in a 3 mon configuration on a single node.

Expected behavior:

Since one deployment does not exist at all (mon-b was deleted) then I would expect that mon-b would be recreated first. Instead what happens is the update for mon-c is prioritized...which attempts to remove it from quorum, which would thus break quorum and thus the operator makes no progress.

How to reproduce it (minimal and precise):

Create 2 node Kubernetes cluster with the example config, and then change the affinity configuration to exclude one of the nodes (in my case I removed control-plane nodes).

rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:23:57.882540 I | op-mon: 2 of 3 expected mon deployments exist. creating new deployment(s).
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:23:57.887354 I | op-mon: deployment for mon rook-ceph-mon-c already exists. updating if needed
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:23:57.893323 I | op-k8sutil: updating deployment "rook-ceph-mon-c" after verifying it is safe to stop
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:23:57.893340 I | op-mon: checking if we can stop the deployment rook-ceph-mon-c
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:23:58.408143 I | util: retrying after 1m0s, last error: deployment rook-ceph-mon-c cannot be stopped. . Error EBUSY: not enough monitors would be available (a) after stopping mons [c]: exit status 16
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:23:59.935151 I | ceph-spec: parsing mon endpoints: a=10.43.160.88:6789,b=10.43.93.122:6789,c=10.43.206.38:6789
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:24:05.635609 I | op-config: successfully applied settings to the mon configuration database
rook-ceph-operator-67d4d4c96c-82f57 rook-ceph-operator 2025-11-12 02:24:58.667283 I | util: retrying after 1m0s, last error: deployment rook-ceph-mon-c cannot be stopped. . Error EBUSY: not enough monitors would be available (a) after stopping mons [c]: exit status 16
** Other Notes **

This scenario is pretty synthetic because this is a very limited test cluster but the behavior is concerning since it doesn't seem like 3 actual nodes would change it: bringing up a replacement mon deployment seems like it should take priority rather then trying to reconfigure one, if the reconfig would necessarily break quorum.

My intended deployment size is 3 node clusters, and this seems like an easy jam to get into.

** Follow Up **

I've attempted to fix this situation by killing the mon-c deployment as well in this test cluster and that simply continues the problem - the operator tries to update mon-a, rather then prioritiziing bringing -b or -c back online - and obviously can't because now the quorum is broken.

Activity

wrouesnel
added
bug
 on Nov 12, 2025
subhamkrai
subhamkrai commented on Nov 12, 2025
subhamkrai
on Nov 12, 2025
Contributor
@wrouesnel which cluster yaml you are using to deploy? If you have less than 3 nodes make sure to it this true

rook/deploy/examples/cluster.yaml

Line 56 in 8424d09

 allowMultiplePerNode: false
wrouesnel
wrouesnel commented on Nov 12, 2025
wrouesnel
on Nov 12, 2025
Author
I definitely have those values set true.

I've got a 3 node cluster up now so I'll try and reproduce, but the issue seemed to be that I kept seeing a config update on an existing mon get prioritized over bringing up a new one. The system actually recovered when I deleted all of them and it remade them.

travisn
travisn commented on Nov 15, 2025
travisn
on Nov 15, 2025
Member
I do see the issue as well. Basically, if the existing mons have some spec update at the same time that one of the mon deployments needs to be re-created, this would be hit. If the operator prioritized creating the missing mon, then it would have gone smoothly.

If there is no update at the same time that the deployment was deleted, then the re-creation of the missing mon deployment does get completed without being blocked on the other mons that are down.

As soon as the mon deployment is deleted, rook will watch for that event and immediately try and create the mon again. Do you know why the update was also needed at the same time? I understand it can happen as you are describing, but just would not expect it to be common. Are you just testing recovery from random events, or what was the scenario for the mon deployment getting deleted while also needing an update at the same time?

wrouesnel
wrouesnel commented on Nov 15, 2025
wrouesnel
on Nov 15, 2025 · edited by wrouesnel
Author
It may have been because I was messing with the affinity rules to get the mon deployment off the master node of the test cluster VMs in a (1:3 master:agent) configuration.

The concern is once it happened it was a pretty nasty wedge - even deleting multiple mon deployments down to read only didn't trigger the operator to fix it, and my exact intended deployment scenario is "3 mons".

I can try to reproduce again.

github-actions
github-actions commented on Jan 15
github-actions
bot
on Jan 15 – with GitHub Actions
This issue has been automatically marked as stale because it has not had recent activity. It will be closed in a week if no further activity occurs. Thank you for your contributions.


github-actions
added
wontfix
 on Jan 15
github-actions
github-actions commented last month
github-actions
bot
last month – with GitHub Actions
This issue has been automatically closed due to inactivity. Please re-open if this still requires investigation.

## 你的任务

请分析上述问题描述，结合 Rook Ceph Operator 的源码（放置在 /home/bowling/argo-cd.clusters.zjusct.io/tmp/github/rook/rook），分析导致该问题的根本原因，并提出解决方案。请注意，解决方案需要兼顾实现难度和系统稳定性，避免引入新的问题。

要求你输出下面两个文档：

1. root_cause_analysis.md：分析导致该问题的根本原因，要求结合 Rook Ceph Operator 的源码进行分析，指出具体的代码位置和逻辑问题。
2. solution_proposal.md：提出解决方案，要求兼顾实现难度和系统稳定性，避免引入新的问题。需要详细描述解决方案的设计思路、实现步骤以及可能的风险和应对措施。
