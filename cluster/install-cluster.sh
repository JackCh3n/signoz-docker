#!/usr/bin/env bash
# =============================================================================
# SigNoz 集群 / 多节点安装脚本（Docker Swarm，离线可用）
#
# 部署拓扑（默认 3 节点）：
#   node1: keeper-0 + clickhouse-0 + postgres
#   node2: keeper-1 + clickhouse-1
#   node3: keeper-2 + HAProxy + 应用副本
#
# 标准流程
#   1. 每个节点（含 manager）执行：
#        sudo bash ./install-cluster.sh --prepare
#   2. 在 node1 初始化 Swarm，其余节点加入（见 cluster/README.md）
#   3. 在 manager 执行：
#        sudo bash ./install-cluster.sh --deploy --nodes node1,node2,node3
#   4. 巡检：
#        bash ./install-cluster.sh --check
#
# 参数
#   --prepare          当前节点加载镜像、准备 /opt/signoz-cluster、生成 histogramQuantile
#   --deploy           在 Swarm manager 打节点标签、部署 stack、执行迁移并等待健康
#   --check            检查服务副本、Keeper、ClickHouse 集群拓扑、SigNoz API
#   --down             删除 stack（保留所有数据卷）
#   --purge            删除 stack 和**当前节点**的数据卷（危险；其他节点需分别执行）
#   --nodes <n1,n2,n3> 首次部署按顺序给节点打 signoz-node=1/2/3 标签
#   --timeout <秒>     等待超时，默认 900
#   -h, --help         显示帮助
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CLUSTER_DIR="${CLUSTER_DIR:-/opt/signoz-cluster}"
STACK_NAME="${STACK_NAME:-signoz}"
NETWORK_NAME="${STACK_NAME}_signoz-cluster"
ACTION=""
NODES_ARG=""
TIMEOUT="900"

c_info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
  cat <<'EOF'
SigNoz 集群 / 多节点安装脚本（Docker Swarm）

每个节点执行：
  sudo bash ./install-cluster.sh --prepare

在 manager 执行：
  sudo bash ./install-cluster.sh --deploy --nodes node1,node2,node3
  bash ./install-cluster.sh --check
  bash ./install-cluster.sh --down
  sudo bash ./install-cluster.sh --purge   # 危险，仅删除当前节点数据卷
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --prepare) ACTION="prepare"; shift ;;
    --deploy)  ACTION="deploy"; shift ;;
    --check)   ACTION="check"; shift ;;
    --down)    ACTION="down"; shift ;;
    --purge)   ACTION="purge"; shift ;;
    --nodes)   NODES_ARG="${2:?--nodes 需要参数}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?--timeout 需要参数}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

[ -n "$ACTION" ] || die "请指定 --prepare / --deploy / --check / --down / --purge"

# ---- 环境文件 --------------------------------------------------------------
load_env() {
  local f
  for f in "$CLUSTER_DIR/.env.cluster" "$CLUSTER_DIR/.env.cluster.example" \
           "$SCRIPT_DIR/.env.cluster" "$SCRIPT_DIR/.env.cluster.example"; do
    if [ -f "$f" ]; then
      c_info "使用环境文件: $f"
      set -a
      # shellcheck source=/dev/null
      . "$f"
      set +a
      return 0
    fi
  done
  return 1
}

apply_defaults() {
  SIGNOZ_VERSION="${SIGNOZ_VERSION:-v0.146.0}"
  COLLECTOR_VERSION="${COLLECTOR_VERSION:-v0.144.14}"
  CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION:-25.12.5}"
  POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
  HAPROXY_VERSION="${HAPROXY_VERSION:-2.9-alpine}"
  SIGNOZ_HTTP_PORT="${SIGNOZ_HTTP_PORT:-8080}"
  OTLP_GRPC_PORT="${OTLP_GRPC_PORT:-4317}"
  OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"
  POSTGRES_USER="${POSTGRES_USER:-signoz}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-signoz}"
  POSTGRES_DB="${POSTGRES_DB:-signoz}"
  SIGNOZ_IMAGE="signoz/signoz:${SIGNOZ_VERSION}"
  COLLECTOR_IMAGE="signoz/signoz-otel-collector:${COLLECTOR_VERSION}"
  CH_IMAGE="clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}"
  KEEPER_IMAGE="clickhouse/clickhouse-keeper:${CLICKHOUSE_VERSION}"
  POSTGRES_IMAGE="postgres:${POSTGRES_VERSION}"
  HAPROXY_IMAGE="haproxy:${HAPROXY_VERSION}"
  export CLUSTER_DIR SIGNOZ_VERSION COLLECTOR_VERSION CLICKHOUSE_VERSION
  export POSTGRES_VERSION HAPROXY_VERSION SIGNOZ_HTTP_PORT OTLP_GRPC_PORT OTLP_HTTP_PORT
  export POSTGRES_USER POSTGRES_PASSWORD POSTGRES_DB
}

require_docker() {
  command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine 20.10+"
  docker info >/dev/null 2>&1 || die "无法连接 Docker daemon（未启动或当前用户无 docker 权限）"
}

require_manager() {
  require_docker
  local state control
  state="$(docker info --format '{{.Swarm.LocalNodeState}}')"
  [ "$state" = "active" ] || die "Swarm 未初始化：请先在 node1 执行 docker swarm init"
  control="$(docker info --format '{{.Swarm.ControlAvailable}}')"
  [ "$control" = "true" ] || die "当前节点不是 Swarm manager，请在 manager 执行该操作"
}

host_arch() {
  local a
  a="$(uname -m)"
  case "$a" in
    x86_64|amd64) echo "amd64" ;;
    aarch64|arm64) echo "arm64" ;;
    *) die "不支持的本机架构: $a" ;;
  esac
}

host_ip() {
  local ip
  ip="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip" ] || ip="<宿主机IP>"
  printf '%s' "$ip"
}

# ---- prepare ---------------------------------------------------------------
do_prepare() {
  c_step "准备节点 $(hostname)"
  require_docker
  load_env || c_warn "未找到 .env.cluster(.example)，使用默认版本"
  apply_defaults

  local arch assets_src
  arch="$(host_arch)"
  c_info "本机架构: ${arch}"

  # 离线包里 assets 与脚本同级；直接从仓库 cluster/ 目录执行时，assets 在仓库根目录
  assets_src="$SCRIPT_DIR/assets"
  if [ ! -d "$assets_src" ] && [ -d "$SCRIPT_DIR/../assets" ]; then
    assets_src="$SCRIPT_DIR/../assets"
  fi
  [ -d "$assets_src" ] || die "找不到 assets 目录（应在离线包根目录或仓库根目录）"

  mkdir -p "$CLUSTER_DIR" 2>/dev/null || die "无法创建 ${CLUSTER_DIR}，请用 sudo 执行"
  if [ "$SCRIPT_DIR" != "$CLUSTER_DIR" ]; then
    c_info "复制配置到 ${CLUSTER_DIR}"
    rm -rf "${CLUSTER_DIR:?}/config" "${CLUSTER_DIR:?}/assets"
    cp -a "$SCRIPT_DIR/config" "$CLUSTER_DIR/config"
    cp -a "$assets_src" "$CLUSTER_DIR/assets"
    install -m 0644 "$SCRIPT_DIR/haproxy.cfg" "$CLUSTER_DIR/haproxy.cfg"
    install -m 0644 "$SCRIPT_DIR/docker-stack.cluster.yaml" "$CLUSTER_DIR/docker-stack.cluster.yaml"
    install -m 0755 "$SCRIPT_DIR/install-cluster.sh" "$CLUSTER_DIR/install-cluster.sh"
    install -m 0644 "$SCRIPT_DIR/README.md" "$CLUSTER_DIR/README.md"
    install -m 0644 "$SCRIPT_DIR/.env.cluster.example" "$CLUSTER_DIR/.env.cluster.example"
  else
    c_info "已在 ${CLUSTER_DIR} 内执行，跳过文件复制"
  fi

  if [ ! -f "$CLUSTER_DIR/.env.cluster" ]; then
    cp "$CLUSTER_DIR/.env.cluster.example" "$CLUSTER_DIR/.env.cluster"
    c_warn "已生成 ${CLUSTER_DIR}/.env.cluster（默认口令 signoz），首次部署前请修改"
  fi

  install -d "$CLUSTER_DIR/bin"
  install -m 0755 "$CLUSTER_DIR/assets/histogram-quantile/histogram-quantile-linux-${arch}" \
    "$CLUSTER_DIR/bin/histogramQuantile"
  c_info "已准备 histogramQuantile（${arch}）"

  local images_dir="$SCRIPT_DIR/images"
  if [ -d "$images_dir" ] && compgen -G "$images_dir/*.tar.gz" >/dev/null; then
    local f
    for f in "$images_dir"/*.tar.gz; do
      c_info "docker load -i $f"
      docker load -i "$f"
    done
  else
    c_warn "未找到 images/*.tar.gz；按镜像已提前导入处理"
  fi

  local img missing=0 img_arch
  for img in "$SIGNOZ_IMAGE" "$COLLECTOR_IMAGE" "$CH_IMAGE" "$KEEPER_IMAGE" "$POSTGRES_IMAGE" "$HAPROXY_IMAGE"; do
    if docker image inspect "$img" >/dev/null 2>&1; then
      img_arch="$(docker image inspect -f '{{.Architecture}}' "$img")"
      if [ "$img_arch" != "$arch" ]; then
        c_err "镜像架构不匹配: ${img} 实际 ${img_arch}，本机 ${arch}"
        missing=$((missing + 1))
      else
        c_info "OK  ${img} (${img_arch})"
      fi
    else
      c_err "缺失 ${img}"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] || die "有 ${missing} 个镜像缺失，请确认离线包 images/ 完整"

  c_step "节点准备完成"
  cat <<EOF
下一步：
  1) 在每个节点都执行一次本脚本的 --prepare
  2) node1: docker swarm init --advertise-addr <node1-IP>
     其他节点: docker swarm join --token <token> <node1-IP>:2377
  3) 在 manager 执行:
     sudo bash ./install-cluster.sh --deploy --nodes node1,node2,node3
EOF
}

# ---- 等待与巡检辅助 --------------------------------------------------------
svc_full() { printf '%s_%s' "$STACK_NAME" "$1"; }

service_replicas() {
  docker service ls --format '{{.Name}} {{.Replicas}}' | awk -v n="$1" '$1 == n {print $2}'
}

wait_replicas() {
  local svc="$1" want="$2" seconds="$3"
  local full deadline current
  full="$(svc_full "$svc")"
  deadline=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    current="$(service_replicas "$full")"
    if [ "$current" = "$want/$want" ]; then
      c_info "服务就绪: ${full} (${current})"
      return 0
    fi
    sleep 5
  done
  docker service ps "$full" --no-trunc || true
  c_err "服务未达到 ${want}/${want}: ${full}（当前: ${current:-未找到}）"
  return 1
}

ch_query() {
  docker run --rm --network "$NETWORK_NAME" --entrypoint clickhouse-client \
    "$CH_IMAGE" --host signoz-clickhouse --query "$1"
}

keeper_query() {
  local k
  for k in signoz-keeper-0 signoz-keeper-1 signoz-keeper-2; do
    if docker run --rm --network "$NETWORK_NAME" --entrypoint clickhouse-keeper-client \
      "$KEEPER_IMAGE" -h "$k" -p 9181 -q "ls /" >/dev/null 2>&1; then
      return 0
    fi
  done
  return 1
}

clickhouse_ready() {
  local count
  count="$(ch_query "SELECT count() FROM system.clusters WHERE cluster = 'cluster'" 2>/dev/null | tr -d '[:space:]')" || return 1
  [ "$count" = "2" ]
}

sig_noz_ready() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 5 "http://127.0.0.1:${SIGNOZ_HTTP_PORT}/api/v1/health" >/dev/null 2>&1
  elif command -v wget >/dev/null 2>&1; then
    wget -qO- --timeout=5 "http://127.0.0.1:${SIGNOZ_HTTP_PORT}/api/v1/health" >/dev/null 2>&1
  else
    return 1
  fi
}

wait_until() {
  local desc="$1" seconds="$2"
  shift 2
  local deadline
  deadline=$((SECONDS + seconds))
  while [ "$SECONDS" -lt "$deadline" ]; do
    if "$@"; then
      c_info "通过: ${desc}"
      return 0
    fi
    sleep 5
  done
  c_err "等待超时: ${desc}"
  return 1
}

wait_migrator() {
  local full deadline state
  full="$(svc_full signoz-migrator)"
  deadline=$((SECONDS + TIMEOUT))
  c_info "等待 schema 迁移完成: ${full}"
  while [ "$SECONDS" -lt "$deadline" ]; do
    state="$(docker service ps "$full" --format '{{.CurrentState}}' 2>/dev/null | sed -n '1p')"
    case "$state" in
      Complete*)
        c_info "迁移完成"
        return 0
        ;;
      Failed*|Rejected*)
        c_err "迁移失败: ${state}"
        docker service logs --tail 120 "$full" || true
        return 1
        ;;
    esac
    sleep 5
  done
  c_err "等待迁移超时"
  docker service ps "$full" --no-trunc || true
  docker service logs --tail 120 "$full" || true
  return 1
}

check_all() {
  local failed=0
  c_step "集群巡检"
  docker service ls --filter "name=${STACK_NAME}_" || true

  echo
  c_info "ClickHouse 集群拓扑（期望 2 行，shard=1，replica=1/2）"
  ch_query "SELECT cluster, shard_num, replica_num, host_name FROM system.clusters WHERE cluster='cluster' ORDER BY replica_num FORMAT PrettyCompact" || failed=1

  echo
  c_info "Keeper 连接检查"
  if keeper_query; then
    c_info "Keeper 可用"
  else
    c_err "Keeper 不可用"
    failed=1
  fi

  echo
  c_info "已创建的复制表数量（期望 > 0）"
  ch_query "SELECT count() AS replicated_tables FROM system.tables WHERE database LIKE 'signoz_%' AND engine LIKE 'Replicated%' FORMAT PrettyCompact" || failed=1

  echo
  c_info "副本只读/延迟（is_readonly 应为 0，absolute_delay 不应持续增长）"
  ch_query "SELECT database, table, is_readonly, absolute_delay FROM system.replicas ORDER BY database, table LIMIT 10 FORMAT PrettyCompact" || failed=1

  echo
  c_info "SigNoz API 健康检查"
  if sig_noz_ready; then
    c_info "SigNoz API 可用"
  else
    c_err "SigNoz API 不可用: http://127.0.0.1:${SIGNOZ_HTTP_PORT}/api/v1/health"
    failed=1
  fi

  [ "$failed" -eq 0 ] || c_warn "巡检存在失败项，请查看上方输出与 docker service logs"
  return "$failed"
}

# ---- deploy ----------------------------------------------------------------
do_deploy() {
  c_step "部署 SigNoz 集群"
  require_manager
  load_env || c_warn "未找到 .env.cluster(.example)，使用默认版本"
  apply_defaults

  [ -f "$CLUSTER_DIR/docker-stack.cluster.yaml" ] || die "缺少 ${CLUSTER_DIR}/docker-stack.cluster.yaml，请先执行 --prepare"
  if [ ! -f "$CLUSTER_DIR/.env.cluster" ]; then
    cp "$CLUSTER_DIR/.env.cluster.example" "$CLUSTER_DIR/.env.cluster"
    c_warn "已生成 ${CLUSTER_DIR}/.env.cluster（默认口令 signoz），首次部署前建议修改"
  fi
  export CLUSTER_DIR

  local -a nodes=()
  if [ -n "$NODES_ARG" ]; then
    IFS=',' read -r -a nodes <<< "$NODES_ARG"
  elif [ -f "$CLUSTER_DIR/.cluster-nodes" ]; then
    mapfile -t nodes < "$CLUSTER_DIR/.cluster-nodes"
  else
    die "首次部署必须提供 --nodes node1,node2,node3（按 node1/node2/node3 顺序）"
  fi
  [ "${#nodes[@]}" -ge 3 ] || die "至少需要 3 个节点（Keeper 3 节点 Raft），当前 ${#nodes[@]} 个"

  local i=0 n state
  for n in "${nodes[@]}"; do
    i=$((i + 1))
    state="$(docker node inspect "$n" --format '{{.Status.State}}' 2>/dev/null || true)"
    [ "$state" = "ready" ] || die "节点不可用或不存在: ${n}（状态: ${state:-unknown}）"
    docker node update --label-add "signoz-node=${i}" "$n" >/dev/null
    c_info "节点 ${n} -> signoz-node=${i}"
  done
  printf '%s\n' "${nodes[@]}" > "$CLUSTER_DIR/.cluster-nodes"

  c_step "部署 stack: ${STACK_NAME}"
  docker stack deploy -c "$CLUSTER_DIR/docker-stack.cluster.yaml" "$STACK_NAME"

  c_step "等待数据层就绪"
  wait_replicas signoz-keeper-0 1 "$TIMEOUT"
  wait_replicas signoz-keeper-1 1 "$TIMEOUT"
  wait_replicas signoz-keeper-2 1 "$TIMEOUT"
  wait_replicas signoz-clickhouse-0 1 "$TIMEOUT"
  wait_replicas signoz-clickhouse-1 1 "$TIMEOUT"
  wait_replicas signoz-clickhouse 2 "$TIMEOUT"
  wait_replicas signoz-postgres 1 "$TIMEOUT"

  c_step "等待 Keeper 法定人数与 ClickHouse 集群"
  wait_until "Keeper 可读" "$TIMEOUT" keeper_query || die "Keeper 未形成法定人数（3 节点至少需要 2 个在线）"
  wait_until "ClickHouse cluster 含 2 个副本" "$TIMEOUT" clickhouse_ready || die "ClickHouse 副本未全部加入 cluster"

  c_step "执行 schema 迁移"
  docker service update --force "$(svc_full signoz-migrator)" >/dev/null
  wait_migrator || die "schema 迁移失败，请查看上方日志"

  c_step "等待应用副本"
  wait_replicas signoz-signoz 2 "$TIMEOUT" || die "SigNoz 副本未就绪"
  wait_replicas signoz-ingester 2 "$TIMEOUT" || die "Collector 副本未就绪"

  c_step "等待 SigNoz API"
  wait_until "SigNoz /api/v1/health" "$TIMEOUT" sig_noz_ready || die "SigNoz API 未通过健康检查"

  check_all || c_warn "部署完成但巡检有失败项"

  local ip
  ip="$(host_ip)"
  c_step "部署完成"
  cat <<EOF
  SigNoz UI      : http://${ip}:${SIGNOZ_HTTP_PORT}
  OTLP gRPC      : http://${ip}:${OTLP_GRPC_PORT}   (任意 Swarm 节点 IP)
  OTLP HTTP      : http://${ip}:${OTLP_HTTP_PORT}
  容器内 OTLP    : http://signoz-ingester:4317

  常用命令：
    docker service ls
    docker service logs -f ${STACK_NAME}_${STACK_NAME}-signoz
    docker service logs -f ${STACK_NAME}_${STACK_NAME}-ingester
    bash ./install-cluster.sh --check
    bash ./install-cluster.sh --down
EOF
}

# ---- down / purge ----------------------------------------------------------
do_down() {
  require_manager
  c_step "删除 stack: ${STACK_NAME}（数据卷保留）"
  docker stack rm "$STACK_NAME"
  local i=0
  while [ "$i" -lt 60 ]; do
    if ! docker stack ls --format '{{.Name}}' | grep -qx "$STACK_NAME"; then
      c_info "stack 已删除"
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  c_warn "stack 删除命令已下发，但仍有残留服务，请检查 docker service ls"
}

do_purge() {
  c_warn "将删除 stack 以及【当前节点】上的数据卷，数据不可恢复"
  do_down
  c_step "删除当前节点数据卷"
  local v
  for v in keeper-0-data keeper-1-data keeper-2-data clickhouse-0-data clickhouse-1-data postgres-data; do
    docker volume rm "${STACK_NAME}_${v}" >/dev/null 2>&1 || true
  done
  c_warn "其他节点上的本地卷不会被远程删除；请在对应节点执行 --purge 或 docker volume rm"
}

# ---- 入口 ------------------------------------------------------------------
case "$ACTION" in
  prepare) do_prepare ;;
  deploy)  do_deploy ;;
  check)   require_manager; load_env || c_warn "未找到 .env.cluster(.example)，使用默认版本"; apply_defaults; check_all ;;
  down)    do_down ;;
  purge)   do_purge ;;
esac
