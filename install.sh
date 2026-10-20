#!/usr/bin/env bash
# =============================================================================
# SigNoz 离线安装 / 启动脚本（在内网目标机执行，全程不需要外网）
#
# 做的事
#  1. 预检 Docker / Compose / 架构 / 镜像包
#  2. docker load 导入镜像包
#  3. docker compose up -d 启动，并等待 SigNoz 健康检查通过
#
# 快速开始
#  tar xzf signoz-offline-<版本>-<架构>.tar.gz
#  cd signoz-offline-<版本>-<架构>
#  ./install.sh --check      # 只预检，不做任何改动
#  ./install.sh              # 导入镜像并启动
#
# 参数
#  --images <file>   指定镜像包（默认自动查找 images/*.tar.gz）
#  --no-load         跳过 docker load（镜像已提前导入时使用）
#  --check           只做预检，不导入、不启动
#  --down            停止并删除容器（保留数据卷）
#  --purge           停止并删除容器及所有数据卷（危险，数据不可恢复）
#  --timeout <秒>    等待健康检查的超时时间，默认 600
#  --no-wait         启动后不等待健康检查
#  --force           跳过架构不匹配检查
#  -h, --help        显示帮助
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

IMAGES_ARG=""
NO_LOAD="no"
CHECK_ONLY="no"
ACTION="install"
WAIT="yes"
TIMEOUT="600"
FORCE="no"

c_info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
  sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --images)  IMAGES_ARG="${2:?--images 需要参数}"; shift 2 ;;
    --no-load) NO_LOAD="yes"; shift ;;
    --check)   CHECK_ONLY="yes"; shift ;;
    --down)    ACTION="down"; shift ;;
    --purge)   ACTION="purge"; shift ;;
    --timeout) TIMEOUT="${2:?--timeout 需要参数}"; shift 2 ;;
    --no-wait) WAIT="no"; shift ;;
    --force)   FORCE="yes"; shift ;;
    -h|--help) usage ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# ---- Docker / Compose 检查 -------------------------------------------------
command -v docker >/dev/null 2>&1 || die "未找到 docker，请先安装 Docker Engine 20.10+"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon：请确认服务已启动，且当前用户在 docker 组（或使用 sudo）"

if docker compose version >/dev/null 2>&1; then
  DC=(docker compose)
elif command -v docker-compose >/dev/null 2>&1; then
  _v="$(docker-compose version --short 2>/dev/null || true)"
  case "$_v" in
    2.*) DC=(docker-compose) ;;
    *) die "检测到 docker-compose ${_v:-v1}，本项目需要 Compose v2（docker compose 插件）" ;;
  esac
else
  die "未找到 Docker Compose v2（docker compose 或 docker-compose v2）"
fi
dc() { "${DC[@]}" "$@"; }

# 停止 / 删除动作不需要读取版本参数
if [ "$ACTION" = "down" ] || [ "$ACTION" = "purge" ]; then
  c_step "$([ "$ACTION" = "purge" ] && echo '停止并删除容器与数据卷' || echo '停止并删除容器')"
  if [ "$ACTION" = "purge" ]; then
    c_warn "将删除所有 SigNoz 数据卷，数据不可恢复"
    dc down --volumes --remove-orphans
  else
    dc down --remove-orphans
  fi
  c_info "完成（$([ "$ACTION" = "purge" ] && echo '数据卷已删除' || echo '数据卷已保留')）"
  exit 0
fi

# ---- 参数文件 --------------------------------------------------------------
ENV_FILE=".env"
if [ -f .env ]; then
  ENV_FILE=".env"
elif [ -f .env.example ]; then
  if [ "$CHECK_ONLY" = "yes" ]; then
    ENV_FILE=".env.example"
    c_info "未找到 .env，预检使用 .env.example 默认值（不会创建文件）"
  else
    cp .env.example .env
    ENV_FILE=".env"
    c_warn "已根据 .env.example 生成 .env，请确认口令与端口（默认口令 signoz）"
  fi
else
  die "缺少 .env / .env.example"
fi

set -a
# shellcheck source=/dev/null
. "./${ENV_FILE}"
set +a

SIGNOZ_VERSION="${SIGNOZ_VERSION:-v0.146.0}"
COLLECTOR_VERSION="${COLLECTOR_VERSION:-v0.144.14}"
CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION:-25.12.5}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
SIGNOZ_HTTP_PORT="${SIGNOZ_HTTP_PORT:-8080}"
OTLP_GRPC_PORT="${OTLP_GRPC_PORT:-4317}"
OTLP_HTTP_PORT="${OTLP_HTTP_PORT:-4318}"

HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)  HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  *) die "不支持的本机架构: $HOST_ARCH" ;;
esac

IMAGES=(
  "signoz/signoz:${SIGNOZ_VERSION}"
  "signoz/signoz-otel-collector:${COLLECTOR_VERSION}"
  "clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}"
  "clickhouse/clickhouse-keeper:${CLICKHOUSE_VERSION}"
  "postgres:${POSTGRES_VERSION}"
)

find_archive() {
  if [ -n "$IMAGES_ARG" ]; then
    [ -f "$IMAGES_ARG" ] || die "镜像包不存在: $IMAGES_ARG"
    printf '%s\n' "$IMAGES_ARG"
    return 0
  fi
  for d in "$SCRIPT_DIR/images" "$SCRIPT_DIR" "$SCRIPT_DIR/dist"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.tar.gz "$d"/*.tgz "$d"/*.tar; do
      [ -f "$f" ] || continue
      case "$(basename "$f")" in
        signoz-offline-*) continue ;;
      esac
      printf '%s\n' "$f"
      return 0
    done
  done
  return 1
}

image_present() {
  docker image inspect "$1" >/dev/null 2>&1
}

ARCHIVE="$(find_archive || true)"

# ---- 离线包架构校验 --------------------------------------------------------
if [ -f BUILD-INFO.txt ]; then
  PKG_ARCH="$(sed -n 's/^Target arch[[:space:]]*:[[:space:]]*//p' BUILD-INFO.txt | head -n 1)"
  if [ -n "$PKG_ARCH" ] && [ "$PKG_ARCH" != "$HOST_ARCH" ]; then
    if [ "$FORCE" = "yes" ]; then
      c_warn "离线包架构 ${PKG_ARCH} 与本机 ${HOST_ARCH} 不一致，--force 已放行"
    else
      die "离线包架构 ${PKG_ARCH} 与本机 ${HOST_ARCH} 不一致，请在目标架构上重新打包或使用 --force"
    fi
  fi
fi

if [ "$CHECK_ONLY" = "yes" ]; then
  c_step "环境预检（不做任何改动）"
  printf '  %-16s %s\n' "Docker" "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo unknown)"
  printf '  %-16s %s\n' "Compose" "$("${DC[@]}" version --short 2>/dev/null | head -n 1 || echo unknown)"
  printf '  %-16s %s\n' "本机架构" "$HOST_ARCH"
  printf '  %-16s %s\n' "SigNoz" "$SIGNOZ_VERSION"
  printf '  %-16s %s\n' "Collector" "$COLLECTOR_VERSION"
  printf '  %-16s %s\n' "ClickHouse" "$CLICKHOUSE_VERSION"
  printf '  %-16s %s\n' "镜像包" "${ARCHIVE:-未找到（可用 --images 指定）}"

  _missing=0
  for img in "${IMAGES[@]}"; do
    if image_present "$img"; then
      printf '  [已有] %s\n' "$img"
    else
      printf '  [缺失] %s\n' "$img"
      _missing=$((_missing + 1))
    fi
  done

  if ! dc config >/dev/null 2>&1; then
    dc config || true
    die "docker-compose.yaml 校验失败"
  fi
  c_info "Compose 文件校验通过"

  if [ "$_missing" -gt 0 ] && [ -z "$ARCHIVE" ]; then
    c_err "有 ${_missing} 个镜像缺失，且未找到镜像包"
    exit 1
  fi
  c_info "预检完成"
  exit 0
fi

# ---- 导入镜像 --------------------------------------------------------------
if [ "$NO_LOAD" = "yes" ]; then
  c_step "跳过镜像导入（--no-load）"
elif [ -n "$ARCHIVE" ]; then
  c_step "导入镜像：${ARCHIVE}"
  c_info "镜像包较大，docker load 可能需要数分钟..."
  docker load -i "$ARCHIVE"
else
  c_warn "未找到镜像包，按镜像已提前导入处理"
fi

c_step "校验镜像"
_missing=0
for img in "${IMAGES[@]}"; do
  if image_present "$img"; then
    c_info "OK  ${img}"
  else
    c_err "缺失 ${img}"
    _missing=$((_missing + 1))
  fi
done
if [ "$_missing" -gt 0 ]; then
  die "有 ${_missing} 个镜像缺失：请把对应架构的离线包传入，或用 --images 指定镜像包"
fi

# ---- 启动 ------------------------------------------------------------------
c_step "启动 SigNoz"
dc up -d --remove-orphans

# ---- 等待健康 --------------------------------------------------------------
if [ "$WAIT" = "yes" ]; then
  c_step "等待 SigNoz 就绪（首次启动需初始化 ClickHouse，最长 ${TIMEOUT} 秒）"
  _start="$SECONDS"
  _ok="no"
  while [ $((SECONDS - _start)) -lt "$TIMEOUT" ]; do
    _st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' signoz-signoz-0 2>/dev/null || echo missing)"
    case "$_st" in
      healthy) _ok="yes"; break ;;
    esac

    _mig="$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' signoz-telemetrystore-migrator 2>/dev/null || true)"
    case "$_mig" in
      "exited "[1-9]*)
        c_err "ClickHouse 迁移容器失败：${_mig}"
        dc logs --tail=60 signoz-telemetrystore-migrator || true
        exit 1
        ;;
    esac

    printf '.'
    sleep 5
  done
  echo
  if [ "$_ok" != "yes" ]; then
    c_err "等待超时，当前状态：${_st:-unknown}"
    dc ps || true
    dc logs --tail=40 signoz-signoz-0 signoz-telemetrystore-migrator signoz-telemetrystore-clickhouse-0-0 || true
    die "启动未完成，请检查上方日志（常见原因：内存不足、端口占用、SELinux）"
  fi
  c_info "SigNoz 健康检查通过"
fi

# ---- API 冒烟测试 ----------------------------------------------------------
_health_url="http://127.0.0.1:${SIGNOZ_HTTP_PORT}/api/v1/health"
_resp=""
if command -v curl >/dev/null 2>&1; then
  _resp="$(curl -fsS --max-time 10 "$_health_url" 2>/dev/null || true)"
elif command -v wget >/dev/null 2>&1; then
  _resp="$(wget -qO- --timeout=10 "$_health_url" 2>/dev/null || true)"
else
  _resp="$(docker exec signoz-signoz-0 wget -qO- --timeout=10 http://localhost:8080/api/v1/health 2>/dev/null || true)"
fi
if printf '%s' "$_resp" | grep -q '"status"[[:space:]]*:[[:space:]]*"ok"'; then
  c_info "API 冒烟测试通过：${_resp}"
else
  c_warn "API 健康检查未返回预期结果：${_resp:-无响应}"
fi

# ---- 输出访问信息 ----------------------------------------------------------
_host_ip="$(hostname -I 2>/dev/null | awk '{print $1}' || true)"
[ -n "$_host_ip" ] || _host_ip="<宿主机IP>"

c_step "部署完成"
echo "  SigNoz UI      : http://${_host_ip}:${SIGNOZ_HTTP_PORT}"
echo "  OTLP gRPC      : http://${_host_ip}:${OTLP_GRPC_PORT}   (Java 应用推荐)"
echo "  OTLP HTTP      : http://${_host_ip}:${OTLP_HTTP_PORT}"
echo "  容器内 OTLP 地址: http://signoz-ingester:4317   (应用需加入 signoz-network)"
echo
echo "  常用命令："
echo "    docker compose ps"
echo "    docker compose logs -f signoz-signoz-0"
echo "    ./install.sh --down      # 停服，保留数据"
echo "    ./install.sh --purge     # 停服并删除数据（危险）"
echo
echo "  Java 应用接入（OpenTelemetry Java Agent）："
echo "    -javaagent:/opt/otel/opentelemetry-javaagent.jar \\"
echo "    -Dotel.service.name=my-java-app \\"
echo "    -Dotel.exporter.otlp.endpoint=http://${_host_ip}:${OTLP_GRPC_PORT} \\"
echo "    -Dotel.resource.attributes=deployment.environment=prod"
echo
