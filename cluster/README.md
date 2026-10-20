# SigNoz 集群 / 多节点模式（Docker Swarm）

> 本目录属于仓库的 `cluster` 实验分支。根目录的 `docker-compose.yaml` / `install.sh` 仍是单机模式，二者互不影响。

## 1. 设计目标

在**不引入 Kubernetes**的前提下，用 Docker Swarm 把 SigNoz 从单机扩展到多节点，重点解决单机模式的三个问题：

1. ClickHouse 单点：改成 1 shard × 2 replicas，任意一个 ClickHouse 节点故障仍可查询/写入；
2. Keeper 单点：改成 3 节点 Raft，容忍 1 个 Keeper 故障；
3. SigNoz / Collector 单副本：改成 2 副本，Swarm routing mesh 自动负载均衡。

PostgreSQL（元数据）仍是单实例，这是本方案**唯一的单点**，见第 10 节限制说明。

## 2. 拓扑

```text
              ┌─────────────────────────────┐
   OTLP ─────▶│ Swarm routing mesh 4317/4318│─────▶ signoz-ingester ×2
              └─────────────────────────────┘
              ┌─────────────────────────────┐
   UI/API ───▶│ Swarm routing mesh 8080     │─────▶ signoz-signoz ×2
              └─────────────────────────────┘
                                                       │
                              ┌────────────────────────┴─────────┐
                              ▼                                  ▼
                       signoz-postgres                  signoz-clickhouse (HAProxy ×2)
                       （元数据，单实例）                         │
                                                    ┌────────────┴────────────┐
                                                    ▼                         ▼
                                          signoz-clickhouse-0       signoz-clickhouse-1
                                          shard=01 replica=01       shard=01 replica=02
                                                    │       ReplicatedMergeTree │
                                                    └────────────┬──────────────┘
                                                                 ▼
                                                    signoz-keeper-0/1/2（Raft）
```

默认 3 节点时的落点：

| 节点 | 固定组件 | 可调度组件 |
|---|---|---|
| node1 | keeper-0、clickhouse-0、postgres | SigNoz / Collector / HAProxy 副本 |
| node2 | keeper-1、clickhouse-1 | SigNoz / Collector / HAProxy 副本 |
| node3 | keeper-2 | SigNoz / Collector / HAProxy 副本 |

组件命名：

- ClickHouse 集群名必须是 `cluster`。SigNoz 的 schema 迁移 SQL 里 `ON CLUSTER` 是硬编码的，改名会导致建表失败。
- 两副本的 macros 分别是 `shard=01, replica=01/02`；`ReplicatedMergeTree` 通过 `{shard}` / `{replica}` 区分数据路径。
- Collector / SigNoz / 迁移任务都连接 `signoz-clickhouse:9000`（HAProxy），不直连某个 ClickHouse 节点。

## 3. 与单机模式的差异

| 项目 | 单机模式 | 集群模式 |
|---|---|---|
| 编排 | Docker Compose | Docker Swarm stack |
| ClickHouse | 1 节点 | 1 shard × 2 replicas |
| Keeper | 1 节点 | 3 节点 Raft |
| SigNoz / Collector | 各 1 副本 | 各 2 副本（可扩） |
| ClickHouse 入口 | 固定容器名 | HAProxy 双副本，故障转移 |
| PostgreSQL | 单实例 | 单实例（相同） |
| 数据卷 | 本机 named volume | 各节点本地 named volume |
| 配置来源 | `config/` | `cluster/config/` |

## 4. 环境要求

| 项目 | 建议 |
|---|---|
| 节点数 | **至少 3 台**（Keeper 3 节点 Raft 的最低要求） |
| 架构 | 所有节点同架构（amd64 或 arm64），不支持混部 |
| CPU / 内存 | 每节点 8 核 / 16 GB 起；3×8C/16G 建议先按第 9 节降低副本，16C/32G 更稳妥 |
| 磁盘 | 每节点 200 GB SSD 起；ClickHouse 数据量按保留周期估算 |
| 网络 | 节点间 1 Gbps、低延迟；Swarm 端口互通 |
| 时间 | **所有节点必须 NTP/chrony 同步**，否则 Keeper 选主与 ClickHouse 复制会异常 |
| Docker | Docker Engine 20.10+，已启用 Swarm |
| 权限 | 能执行 `docker`；`--prepare` 需要写 `/opt`，建议 `sudo` |

端口：

- 对外：`8080`（UI/API）、`4317`（OTLP gRPC）、`4318`（OTLP HTTP）
- Swarm 控制面：TCP `2377`、TCP/UDP `7946`、UDP `4789`
- 仅 overlay 内：ClickHouse `9000/8123/9009`、Keeper `9181/9234`、Postgres `5432`

## 5. 制作集群离线包（联网机）

```bash
cd signoz-docker
bash cluster/bundle-cluster.sh --arch amd64
# ARM 环境：bash cluster/bundle-cluster.sh --arch arm64
```

产物：

```text
dist/signoz-cluster-offline-v0.146.0-amd64.tar.gz
dist/signoz-cluster-offline-v0.146.0-amd64.tar.gz.sha256
```

包内含 6 个镜像（多一个 HAProxy）、集群配置、Swarm stack 文件、安装脚本和本说明。

## 6. 离线部署

### 6.1 每个节点：解压并准备

把离线包复制到**每个节点**，统一放到 `/opt/signoz-cluster`：

```bash
sha256sum -c signoz-cluster-offline-v0.146.0-amd64.tar.gz.sha256
sudo tar xzf signoz-cluster-offline-v0.146.0-amd64.tar.gz -C /opt
sudo mv /opt/signoz-cluster-offline-v0.146.0-amd64 /opt/signoz-cluster
cd /opt/signoz-cluster

# 每个节点都执行：加载 6 个镜像、准备配置、生成 histogramQuantile
sudo bash ./install-cluster.sh --prepare
```

`--prepare` 会：

- 把 `config/`、`assets/`、`haproxy.cfg`、stack 文件复制到 `/opt/signoz-cluster`；
- 生成 `/opt/signoz-cluster/bin/histogramQuantile`（按本机架构选择 amd64/arm64）；
- `docker load` 离线镜像；
- 生成 `.env.cluster`（首次），并校验 6 个镜像都存在。

> 只在 manager 上执行 `--prepare` 不够：ClickHouse/Keeper/Postgres 任务可能被调度到其他节点，镜像必须提前加载到**每个**节点。

### 6.2 初始化 Swarm

在 node1：

```bash
# 换成 node1 的内网 IP
docker swarm init --advertise-addr 192.168.1.11

# 查看加入命令
docker swarm join-token worker
docker swarm join-token manager
```

在 node2、node3 执行 `docker swarm join`。

推荐 3 个节点都作为 **manager**（控制面 Raft 容忍 1 节点故障）；如果先以 worker 加入，可以在 node1 上提升：

```bash
docker node promote node2 node3
docker node ls
```

> 3 个 manager 时 Swarm 控制面才有高可用；单 manager 故障后不影响已运行容器，但无法再调度/更新服务。

### 6.3 首次部署（manager）

```bash
cd /opt/signoz-cluster

# 首次部署前修改数据库口令（默认 signoz）
sudo vi .env.cluster

# node1,node2,node3 是 docker node ls 里的 Hostname，顺序决定落点：
#   第 1 个 -> clickhouse-0 + keeper-0 + postgres
#   第 2 个 -> clickhouse-1 + keeper-1
#   第 3 个 -> keeper-2
sudo bash ./install-cluster.sh --deploy --nodes node1,node2,node3
```

脚本会：

1. 校验节点存在且 Ready，写入 `signoz-node=1/2/3` 标签；
2. `docker stack deploy`；
3. 等待 Keeper 3 节点、ClickHouse 2 副本、HAProxy、Postgres 就绪；
4. 等待 Keeper 形成法定人数、ClickHouse `cluster` 中出现 2 个副本；
5. 强制重跑 `signoz-migrator`，等待 bootstrap/sync/async 迁移完成；
6. 等待 SigNoz / Collector 各 2 副本、`/api/v1/health` 通过；
7. 执行集群巡检并输出访问地址。

首次启动需要初始化 ClickHouse 与执行 schema 迁移，通常 3–10 分钟。

### 6.4 验证

```bash
cd /opt/signoz-cluster
bash ./install-cluster.sh --check

curl -fsS http://<任意节点IP>:8080/api/v1/health
```

访问 `http://<任意节点IP>:8080`；OTLP 端点 `http://<任意节点IP>:4317` / `:4318`。

## 7. 扩缩容

SigNoz 与 Collector 是无状态副本，可以直接扩：

```bash
# Web/API
docker service scale signoz_signoz-signoz=3

# OTLP Collector
docker service scale signoz_signoz-ingester=3
```

查看副本落点：

```bash
docker service ps signoz_signoz-signoz
docker service ps signoz_signoz-ingester
```

ClickHouse 当前是 **1 shard × 2 replicas**（高可用，不做水平分片）。如需增加分片：

1. 新增 `signoz-clickhouse-2/3` 服务与配置，修改所有节点的 `<remote_servers>` 为 2 个 shard；
2. 把 HAProxy 后端加入新节点；
3. 重新执行 `--prepare` 和迁移，让 `ON CLUSTER` 在新节点建表。

这是进阶改造，不在当前默认配置中；生产上更推荐直接使用 SigNoz 官方 Helm Chart（Kubernetes）做分片。

## 8. 日常运维

```bash
# 服务与副本
docker service ls
docker service ps signoz_signoz-clickhouse-0

# 日志
docker service logs -f signoz_signoz-signoz
docker service logs -f signoz_signoz-ingester
docker service logs -f signoz_signoz-clickhouse-0
docker service logs -f signoz_signoz-migrator

# 暂停 / 恢复
bash ./install-cluster.sh --down        # 删除 stack，保留数据卷
bash ./install-cluster.sh --deploy      # 重新部署（读取 .cluster-nodes）

# 节点
docker node ls
docker node inspect node1 --pretty
```

停止后数据卷仍保留在各节点。重新部署时使用相同的 `.cluster-nodes` 顺序和 `signoz-node` 标签，保证 ClickHouse/Postgres 回到原节点、挂回原数据卷。

## 9. 资源调整

默认在 stack 文件中给每个服务设置了 `deploy.resources.limits`：

| 服务 | CPU | 内存 |
|---|---|---|
| ClickHouse（每个） | 2 | 4 GB |
| Keeper（每个） | 1 | 1 GB |
| PostgreSQL | 2 | 2 GB |
| SigNoz（每个） | 2 | 2 GB |
| Collector（每个） | 2 | 2 GB |
| HAProxy（每个） | 0.5 | 256 MB |

如果节点规格较小（例如 3 × 4C/8G），先降低 ClickHouse 内存（同时修改 `cluster/config/clickhouse/users.xml` 的 `max_memory_usage` 和 `cluster-*.xml` 的 `max_server_memory_usage`），并把 SigNoz/Collector 副本降到 1。3 × 8C/16G 可以跑默认的 2+2 副本，但 CPU 余量不大；生产建议 16C/32G。

ClickHouse 内存修改位置：

- `cluster/config/clickhouse/cluster-0.xml`、`cluster-1.xml`：`max_server_memory_usage`
- `cluster/config/clickhouse/users.xml`：`profiles.default.max_memory_usage`

修改后需要在每个节点重新 `--prepare`，并强制重建 ClickHouse 服务：

```bash
docker service update --force signoz_signoz-clickhouse-1
# 等待副本恢复后再更新 0
docker service update --force signoz_signoz-clickhouse-0
```

## 10. 故障行为与限制

### 10.1 故障行为

| 故障 | 影响 | 恢复 |
|---|---|---|
| 1 个 Keeper 宕机 | 无影响（2/3 quorum） | 重启该节点 Keeper，自动重新加入 |
| 1 个 ClickHouse 宕机 | HAProxy 摘除故障副本；写入/查询切到另一副本 | 重启后 `ReplicatedMergeTree` 自动追平 |
| SigNoz 某副本宕机 | routing mesh 转发到另一副本 | Swarm 自动重启/迁移 |
| Collector 某副本宕机 | 客户端重连到另一副本 | Swarm 自动重启/迁移 |
| 1 个 HAProxy 副本宕机 | 另一副本继续服务 | Swarm 自动重启 |
| **PostgreSQL 所在节点宕机** | **UI/API 不可用；OTLP 采集继续写入 ClickHouse** | 恢复节点或从备份恢复数据库 |
| node1 永久损坏 | clickhouse-0/keeper-0/postgres 无法按标签调度 | 用新节点补 label=1；CH-0 从 CH-1 重建，Postgres 从备份恢复 |

### 10.2 限制

1. **PostgreSQL 单实例**：这是本方案唯一的元数据单点。UI/API 的高可用依赖它；采集链路不依赖。生产环境建议把 `SIGNOZ_SQLSTORE_POSTGRES_DSN` 指向外部 HA PostgreSQL（Patroni / 云数据库）。
2. **默认不做水平分片**：1 shard × 2 replicas 解决高可用，不解决单 shard 写入上限。数据量很大时请转 Kubernetes + Helm 集群方案。
3. **Docker Swarm 已进入维护模式**：功能稳定但不再快速演进；大型生产集群优先 Kubernetes。
4. **本地数据卷**：ClickHouse/Keeper/Postgres 使用节点本地卷，节点永久损坏时数据不会自动漂移；必须依赖副本或备份。
5. **升级顺序**：`docker stack deploy` 可能同时重启两个 ClickHouse 服务，造成短暂写入中断。生产升级请按第 11 节手动逐个更新。
6. **无内置 TLS / 认证**：UI 和 OTLP 端口默认无认证；集群内部 ClickHouse 使用 default 空口令。请只在内网开放，必要时前置 Nginx / VPN / SSO。
7. **同架构**：离线包和 Swarm 节点必须同为 amd64 或同为 arm64。

## 11. 升级与备份

### 11.1 升级

```bash
# 1) 联网机制作新版本离线包
bash cluster/bundle-cluster.sh --arch amd64

# 2) 分发到每个节点，分别 --prepare（会加载新镜像）
sudo bash ./install-cluster.sh --prepare

# 3) 在 manager 修改 .env.cluster 中的版本号
vi /opt/signoz-cluster/.env.cluster

# 4) 谨慎升级有状态组件：Keeper 一次一个，确保 2/3 quorum
docker service update --image clickhouse/clickhouse-keeper:<新版本> signoz_signoz-keeper-2
# 等待恢复后，再更新 keeper-1、keeper-0

# 5) ClickHouse 先更新 replica-02，再更新 replica-01
docker service update --image clickhouse/clickhouse-server:<新版本> signoz_signoz-clickhouse-1
docker service update --image clickhouse/clickhouse-server:<新版本> signoz_signoz-clickhouse-0

# 6) 更新迁移镜像并重跑迁移
docker service update --image signoz/signoz-otel-collector:<新版本> signoz_signoz-migrator
docker service update --force signoz_signoz-migrator
docker service logs -f signoz_signoz-migrator

# 7) 更新无状态组件（滚动）
docker service update --image signoz/signoz:<新版本> signoz_signoz-signoz
docker service update --image signoz/signoz-otel-collector:<新版本> signoz_signoz-ingester
```

升级前务必先备份 PostgreSQL 和 ClickHouse。

### 11.2 备份

PostgreSQL（任意节点）：

```bash
docker run --rm --network signoz_signoz-cluster \
  -e PGPASSWORD='<你的密码>' \
  postgres:16 pg_dump -h signoz-postgres -U signoz -d signoz -Fc \
  > signoz-postgres-$(date +%F).dump
```

ClickHouse（在对应节点执行；卷名带 stack 前缀）：

```bash
# 先停掉一个副本，避免拷贝过程中 part 变化
docker service scale signoz_signoz-clickhouse-1=0

docker run --rm \
  -v signoz_clickhouse-1-data:/var/lib/clickhouse \
  -v "$PWD:/backup" \
  clickhouse/clickhouse-server:25.12.5 \
  tar czf /backup/clickhouse-1-$(date +%F).tar.gz -C /var/lib/clickhouse .

docker service scale signoz_signoz-clickhouse-1=1
```

另一副本仍在服务，HAProxy 不会中断。恢复时把卷解压回空数据目录后启动副本，`ReplicatedMergeTree` 会从另一副本重新同步。

> 对数据一致性要求高时，建议使用 `clickhouse-backup` 或 ClickHouse 原生 `BACKUP` 命令；上面的冷备份适合小规模内网环境。

## 12. 排障

| 现象 | 排查 |
|---|---|
| `--deploy` 报服务未就绪 | `docker service ps <服务>`、`docker service logs <服务>`；确认节点标签 `signoz-node` 和镜像已 `--prepare` |
| 迁移失败 | `docker service logs signoz_signoz-migrator`；先确认 `bash ./install-cluster.sh --check` 中 Keeper/ClickHouse 两行正常 |
| Keeper 无 quorum | 3 个 Keeper 是否至少 2 个 Running；节点时间是否同步；overlay 网络是否通 |
| ClickHouse 副本只读/延迟 | 查 `system.replicas` 的 `is_readonly`、`absolute_delay`；看 ClickHouse 日志中 Keeper 连接与 `interserver_http_host` 解析 |
| HAProxy 后端全部 DOWN | 在 manager 上 `docker run --rm --network signoz_signoz-cluster --entrypoint clickhouse-client clickhouse/clickhouse-server:25.12.5 --host signoz-clickhouse-0 --query 'SELECT 1'`；确认 CH 服务 DNS 与端口 |
| SigNoz API 健康检查失败 | `docker service logs signoz_signoz-signoz`；确认 Postgres 就绪、迁移已完成、ClickHouse 可查 |
| 服务一直 Pending | `docker node ls` 看节点 Ready；`docker node inspect <node> --format '{{json .Spec.Labels}}'` 看 `signoz-node` |
| 时间戳偏移 / 复制异常 | 所有节点启用 chrony/NTP，检查 `timedatectl` |

## 13. 目录与文件

```text
cluster/
├── .env.cluster.example        # 集群版本、端口、Postgres 口令
├── docker-stack.cluster.yaml   # Swarm stack（服务、端口、资源、放置约束）
├── haproxy.cfg                 # ClickHouse TCP/HTTP 负载均衡
├── install-cluster.sh          # prepare / deploy / check / down / purge
├── bundle-cluster.sh           # 离线包制作（6 镜像 + 配置 + 文档）
├── README.md                   # 本文档
└── config/
    ├── clickhouse/
    │   ├── cluster-0.xml       # replica-01 的 cluster.d 片段
    │   ├── cluster-1.xml       # replica-02 的 cluster.d 片段
    │   ├── users.xml           # users.d，default 用户与内存限制
    │   └── functions.yaml      # histogramQuantile UDF
    ├── keeper/
    │   ├── keeper-0.yaml       # Raft server_id=0
    │   ├── keeper-1.yaml       # Raft server_id=1
    │   └── keeper-2.yaml       # Raft server_id=2
    └── ingester/
        ├── ingester.yaml       # 集群版 Collector，写入 signoz-clickhouse:9000
        └── opamp.yaml          # 指向 signoz-signoz:4320
```

## 14. 为什么不用 Docker Compose 直接跨主机

Docker Compose 是单主机编排，无法原生提供跨节点 overlay 网络、服务发现和副本调度。多节点需要 Swarm（本方案）或 Kubernetes。Swarm 与本仓库现有 Docker 资产（镜像、配置、离线包）最接近，迁移成本最低；Kubernetes 方案适合更大规模，建议后续单独用 SigNoz 官方 Helm Chart 实现。
