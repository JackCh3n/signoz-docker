# signoz-docker

**SigNoz 单机 Docker Compose 部署，面向内网 / 离线环境**

在联网机器上把镜像与配置打成一个离线包，传入内网后执行一条命令即可导入镜像并启动，全程不需要访问 Docker Hub 或 GitHub。

- 清单来源：SigNoz 官方 [Foundry](https://github.com/SigNoz/foundry) v0.3.0 生成的 Docker Compose，版本已固定
- 适用场景：单机自建可观测平台，监控 Java / Spring Boot 等应用（Traces、Metrics、Logs）
- 默认组件：SigNoz、OpenTelemetry Collector（SigNoz 发行版）、ClickHouse、ClickHouse Keeper、PostgreSQL

---

## 1. 版本与组件

| 组件 | 镜像 | 版本 |
|---|---|---|
| SigNoz 后端 / 前端 | `signoz/signoz` | `v0.146.0` |
| OTLP Collector | `signoz/signoz-otel-collector` | `v0.144.14` |
| 遥测存储 | `clickhouse/clickhouse-server` | `25.12.5` |
| 协调服务 | `clickhouse/clickhouse-keeper` | `25.12.5` |
| 元数据存储 | `postgres` | `16` |

版本集中定义在 [.env.example](.env.example)，升级时修改版本号并重新打包即可。Collector 与 SigNoz 的版本搭配需遵循官方兼容矩阵，不建议只单独升级其中一个。

> 官方自 SigNoz `v0.130.0` 起已弃用旧的 `deploy/` Compose 与 `install.sh`，推荐使用 Foundry 管理。本项目使用 Foundry 生成清单后做了**固定版本 + 离线化**改造，保留 Compose 的简单可控，不改变官方组件拓扑。

## 2. 资源与端口

| 项目 | 要求 |
|---|---|
| 内存 | 至少 4 GB（推荐 8 GB 以上，ClickHouse 较吃内存） |
| 磁盘 | 至少 10 GB 可用（镜像约 2 GB，另需数据空间） |
| CPU | 2 核以上 |
| 端口 | `8080`（UI/API）、`4317`（OTLP gRPC）、`4318`（OTLP HTTP） |

ClickHouse、PostgreSQL、Keeper 均只在容器网络 `signoz-network` 内通信，不对外暴露。

## 3. 目录结构

```
signoz-docker/
├── docker-compose.yaml                  # 固定版本的编排文件
├── .env.example                         # 版本、端口、数据库口令
├── bundle.sh                            # 联网机：拉镜像 + 打离线包
├── install.sh                           # 内网机：导入镜像 + 启动 + 健康检查
├── config/                              # 各组件配置（来自 Foundry 生成）
│   ├── ingester/ingester.yaml
│   ├── ingester/opamp.yaml
│   ├── telemetrykeeper/clickhousekeeper/keeper-0.yaml
│   └── telemetrystore/clickhouse/
│       ├── config-0-0.yaml
│       └── functions.yaml
├── assets/histogram-quantile/           # 离线内置的 ClickHouse 函数二进制
│   ├── histogram-quantile-linux-amd64
│   └── histogram-quantile-linux-arm64
└── dist/                                # 打包产物（不入库）
```

## 4. 内网离线部署（推荐）

### 4.1 联网机器：制作离线包

前置条件：Docker Engine 20.10+，能访问 Docker Hub（或已配置可用的 registry mirror）。

```bash
cd signoz-docker

# x86_64（默认）
./bundle.sh

# ARM64（银河麒麟 / 鲲鹏等）
./bundle.sh --arch arm64

# 同时打包 OpenTelemetry Java Agent（内网 Java 应用可直接使用）
./bundle.sh --with-java-agent
```

产物：

```
dist/signoz-offline-v0.146.0-amd64.tar.gz
dist/signoz-offline-v0.146.0-amd64.tar.gz.sha256
```

离线包内含：5 个镜像的 `docker save` 包、Compose 文件、全部配置、两个架构的 histogram-quantile 二进制、安装脚本和 Java Agent（如果指定了 `--with-java-agent`）。

> 打包机与目标机架构不同也没关系：`bundle.sh --arch arm64` 会按目标架构拉取镜像，`docker save` 只包含该架构的镜像层。

### 4.2 传入内网并安装

```bash
# 1) 校验并解压（在目标机执行）
sha256sum -c signoz-offline-v0.146.0-amd64.tar.gz.sha256
tar xzf signoz-offline-v0.146.0-amd64.tar.gz
cd signoz-offline-v0.146.0-amd64

# 2) 预检：只检查环境与镜像，不做任何改动
./install.sh --check

# 3) 导入镜像并启动（首次启动会初始化 ClickHouse，可能需要几分钟）
./install.sh
```

安装脚本会：

1. 检查 Docker / Compose v2 / 架构是否匹配；
2. `docker load` 导入离线镜像；
3. `docker compose up -d` 启动，并等待 SigNoz 健康检查通过；
4. 请求 `/api/v1/health` 做一次 API 冒烟测试；
5. 输出 UI 与 OTLP 地址。

完成后访问：

```
http://<内网服务器IP>:8080
```

### 4.3 端口与口令调整

首次执行 `install.sh` 时会自动把 `.env.example` 复制为 `.env`。如需修改端口或数据库口令，请在**首次启动前**编辑 `.env`：

```bash
cp .env.example .env
vi .env
./install.sh
```

```ini
SIGNOZ_HTTP_PORT=8080
OTLP_GRPC_PORT=4317
OTLP_HTTP_PORT=4318
POSTGRES_USER=signoz
POSTGRES_PASSWORD=signoz     # 建议改为强口令，仅使用字母/数字/下划线
POSTGRES_DB=signoz
```

> 数据库口令若在首次启动后修改，`.env` 与 PostgreSQL 中已初始化的口令会不一致，服务将无法连接。此时需进入数据库执行 `ALTER USER`，或删除数据卷重建（会丢失历史数据）。

### 4.4 常用运维命令

```bash
docker compose ps                         # 容器状态
docker compose logs -f signoz-signoz-0    # 查看 SigNoz 日志
docker compose logs -f ingester           # 查看 OTLP 接入日志

./install.sh --down                       # 停止并删除容器，保留数据卷
./install.sh --purge                      # 停止并删除容器及所有数据（危险）
```

## 5. Java 应用接入

### 5.1 方式一：OpenTelemetry Java Agent（推荐，零代码改动）

在联网机器下载 Agent（或打包时加 `--with-java-agent`，离线包内路径为
`assets/otel-javaagent/opentelemetry-javaagent.jar`）：

```bash
curl -L -o opentelemetry-javaagent.jar \
  https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/v2.32.0/opentelemetry-javaagent.jar
```

启动 Java 应用时附加：

```bash
java -javaagent:/opt/otel/opentelemetry-javaagent.jar \
  -Dotel.service.name=my-java-app \
  -Dotel.exporter.otlp.endpoint=http://<SigNoz服务器IP>:4317 \
  -Dotel.exporter.otlp.protocol=grpc \
  -Dotel.resource.attributes=deployment.environment=prod,service.version=1.0.0 \
  -jar app.jar
```

也可以用环境变量（更适合容器化部署）：

```bash
export JAVA_TOOL_OPTIONS="-javaagent:/opt/otel/opentelemetry-javaagent.jar"
export OTEL_SERVICE_NAME=my-java-app
export OTEL_EXPORTER_OTLP_ENDPOINT=http://<SigNoz服务器IP>:4317
export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
export OTEL_RESOURCE_ATTRIBUTES=deployment.environment=prod,service.version=1.0.0
export OTEL_METRICS_EXPORTER=otlp
export OTEL_LOGS_EXPORTER=otlp
```

### 5.2 方式二：Java 应用容器直接加入 SigNoz 网络

Java 应用也在 Docker 中时，加入 `signoz-network` 后用服务别名访问，不经过宿主机端口：

```yaml
services:
  my-java-app:
    image: my-java-app:1.0.0
    environment:
      JAVA_TOOL_OPTIONS: "-javaagent:/opt/otel/opentelemetry-javaagent.jar"
      OTEL_SERVICE_NAME: my-java-app
      OTEL_EXPORTER_OTLP_ENDPOINT: http://signoz-ingester:4317
      OTEL_EXPORTER_OTLP_PROTOCOL: grpc
      OTEL_RESOURCE_ATTRIBUTES: deployment.environment=prod
    volumes:
      - ./opentelemetry-javaagent.jar:/opt/otel/opentelemetry-javaagent.jar:ro
    networks:
      - signoz-network

networks:
  signoz-network:
    external: true
    name: signoz-network
```

### 5.3 验证接入

1. 打开 `http://<服务器IP>:8080`；
2. 进入 **Services**，应能看到 `my-java-app`；
3. 进入 **Traces**，发起一次业务请求，应出现对应的调用链；
4. 进入 **Metrics**，可查看 JVM、HTTP 服务端等自动采集指标。

> 采集端默认开启 OTLP 的 traces / metrics / logs 三条管道；Java Agent 默认会上报 traces 与 metrics，日志采集需设置 `OTEL_LOGS_EXPORTER=otlp`。

## 6. 网络与安全

- 默认仅暴露 `8080 / 4317 / 4318`。内网环境请在防火墙中放行这三个端口，且只对可信网段开放。
- SigNoz 社区版自建默认没有登录认证。不要把 `8080` 直接暴露到公网；如需公网访问，请在前面加 Nginx / VPN / SSO 网关。
- OTLP 端口同样没有认证，建议只允许应用服务器访问。
- ClickHouse、PostgreSQL、Keeper 没有映射到宿主机端口，风险可控。
- 如宿主机启用 SELinux（CentOS / RHEL 常见），配置文件的挂载已加 `:z` 标签，正常情况下可直接启动；若仍报 `Permission denied`，可查看 `ausearch -m avc -ts recent` 定位。

## 7. 升级

```bash
# 1) 联网机修改 .env 中的版本号（并确认 SigNoz / Collector 版本兼容）
vi .env

# 2) 重新打包
./bundle.sh --arch arm64

# 3) 内网解压新包并执行安装（数据卷会自动复用）
tar xzf signoz-offline-<新版本>-<架构>.tar.gz
cd signoz-offline-<新版本>-<架构>
./install.sh
```

升级前建议备份数据卷。最小备份方式：

```bash
./install.sh --down
docker run --rm -v signoz-metastore-postgres-0-data:/pg \
  -v "$PWD:/backup" postgres:16 \
  tar czf /backup/postgres-data-$(date +%F).tar.gz -C /pg .
docker run --rm -v signoz-telemetrystore-0-0-data:/ch \
  -v "$PWD:/backup" clickhouse/clickhouse-server:25.12.5 \
  tar czf /backup/clickhouse-data-$(date +%F).tar.gz -C /ch .
```

> 跨较大版本升级前，请先在测试环境验证。ClickHouse 版本与 Collector 版本存在兼容下限，不建议跳过本项目给出的版本组合随意替换。

## 8. 常见问题

**1. `install.sh` 提示镜像缺失**

离线包与 `.env` 中的版本必须一致。若只替换了镜像包而没有同步 `.env`，请修改 `.env`，或用 `--images <file>` 指定镜像包。

**2. 架构不匹配**

`x86_64` 环境需要 `amd64` 包，鲲鹏 / 麒麟 ARM 环境需要 `arm64` 包。脚本会读取 `BUILD-INFO.txt` 中的 `Target arch` 并拦截。

**3. 启动后 8080 打不开**

```bash
docker compose ps
docker compose logs --tail=100 signoz-signoz-0
```

首次启动需要初始化 ClickHouse 与执行迁移，耐心等待几分钟。若 `signoz-telemetrystore-migrator` 反复失败，优先检查磁盘空间与内存。

**4. ClickHouse 因内存不足被 OOM Kill**

`dmesg -T | grep -i oom` 可确认。建议给服务器至少 8 GB 内存，或限制 ClickHouse 内存（在 `config/telemetrystore/clickhouse/config-0-0.yaml` 的 `profiles.default` 下增加 `max_memory_usage`）。

**5. 端口被占用**

```bash
ss -lntp | grep -E '8080|4317|4318'
```

修改 `.env` 中对应端口后重新 `./install.sh`。

**6. `docker compose` 命令不存在**

需要 Docker Compose v2 插件。CentOS 7 等旧系统若只有 `docker-compose` v1，请先升级 Docker Engine 或单独安装 Compose v2 插件；本项目使用的 `depends_on` 完成态条件依赖 v2。

**7. 内网启动时 user-scripts 容器失败**

正常情况应使用离线包内置的 `assets/histogram-quantile/` 二进制。若该目录被删空，容器会回退到 GitHub 下载并在内网失败。重新解压离线包即可。

**8. 修改了配置文件不生效**

```bash
docker compose up -d --force-recreate
```

## 9. 组件来源与许可

- Compose 清单与配置由 [SigNoz Foundry](https://github.com/SigNoz/foundry) 生成；
- `histogram-quantile` 二进制来自 SigNoz 官方 Release，许可证见 [assets/histogram-quantile/LICENSE](assets/histogram-quantile/LICENSE)；
- SigNoz、ClickHouse、PostgreSQL 等组件遵循各自上游许可协议，本项目仅提供部署编排与离线打包脚本。
