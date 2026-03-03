# Rook Ceph OSD ID 识别错误问题

## 问题描述

在 e0bb2cea151100e1538427a8728d49b3804a8a59 中我们改变了 Ceph Pod 的资源限制，29 个 OSD 被 Rook Ceph Operator 自动重新部署。在重新部署过程中，发生了一对盘认错的问题。

```
kubectl logs rook-ceph-osd-13-764c99fc5d-mwwq5 -n rook-ceph
+ OSD_ID=13
+ OSD_UUID=46b9e094-5f47-4620-a417-d48cfcfb0d21
+ OSD_STORE_FLAG=--bluestore
+ OSD_DATA_DIR=/var/lib/ceph/osd/ceph-13
+ KEYRING_FILE=/var/lib/ceph/osd/ceph-13/keyring
+ CV_MODE=raw
+ DEVICE=/dev/nvme1n1
+ ENCRYPTED=false
+ '[' false == true ']'
+ [[ raw == \l\v\m ]]
++ mktemp
+ OSD_LIST=/tmp/tmp.8myjzbiOyc
+ ceph-volume raw list /dev/nvme1n1
+ cat /tmp/tmp.8myjzbiOyc
{
    "b87af9f9-05e9-450f-b8c4-b9a902ccc00a": {
        "ceph_fsid": "356ad2aa-0c04-452f-a0e7-ded4c0a5899b",
        "device": "/dev/nvme1n1",
        "osd_id": 2,
        "osd_uuid": "b87af9f9-05e9-450f-b8c4-b9a902ccc00a",
        "type": "bluestore"
    }
}
+ find_device
+ python3 -c '
import sys, json
for _, info in json.load(sys.stdin).items():
        if info['\''osd_id'\''] == 13:
                print(info['\''device'\''], end='\'''\'')
                print('\''found device: '\'' + info['\''device'\''], file=sys.stderr) # log the disk we found to stderr
                sys.exit(0)  # don'\''t keep processing once the disk is found
sys.exit('\''no disk found with OSD ID 13'\'')
'
no disk found with OSD ID 13
+ ceph-volume raw list
```

可以看到，OSD ID 13 被错误地识别为 OSD ID 2 的设备 `/dev/nvme1n1`，导致 OSD 13 无法正确启动。

## 你的任务

1. 分析 K8S 集群历史记录，还原问题现场，理清问题原因。比如，你可以寻找 OSD 2 的 Pod，它是否有被错误分配，然后自动将相应盘重建成了 2？此外你应该自主尝试搜集更多的日志和信息来支持你的分析。
2. 阅读 Rook Ceph 源码，分析 OSD ID 和设备识别的逻辑，找出可能导致这个问题的代码路径。
3. 提出修复方案，说明你打算如何修改 Rook Ceph 的代码来解决这个问题，并确保 OSD ID 和设备的正确识别。

你可以在本项目目录的 tmp/github 下找到相关项目的源代码仓库，比如 tmp/github/rook/rook 和 tmp/github/ceph/ceph。

请你输出一份该问题的分析报告，包含以上三个方面的内容。
