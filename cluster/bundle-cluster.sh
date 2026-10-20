#!/usr/bin/env bash
# =============================================================================
# SigNoz 集群离线包制作脚本（在联网、有 Docker 的机器上执行）
#
# 产物
#   dist/signoz-cluster-offline-<SigNoz版本>-<架构>.tar.gz
#
# 包内包含
#   - 6 个镜像：SigNoz、Collector、ClickHouse Server、ClickHouse Keeper、
#     PostgreSQL、HAProxy（docker save 单包）
#   - docker-stack.cluster.yaml、集群版 ClickHouse/Keeper/Collector 配置
#   - install-cluster.sh、haproxy.cfg、cluster README
#   - 双架构 histogram-quantile 二进制
#
# 用法
#   bash ./bundle-cluster.sh                  # 本机架构
#   bash ./bundle-cluster.sh --arch arm64     # 为 ARM64 打包
#   bash ./bundle-cluster.sh --output /data   # 自定义输出目录
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$ROOT_DIR"

OUT_DIR="$ROOT_DIR/dist"
ARCH=""

c_info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
  cat <<'EOF'
SigNoz 集群离线包制作

用法：
  bash ./bundle-cluster.sh [--arch amd64|arm64] [--output DIR]

  --arch     目标架构，默认本机架构
  --output   输出目录，默认 ../dist
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)   ARCH="${2:?--arch 需要参数}"; shift 2 ;;
    --output) OUT_DIR="${2:?--output 需要参数}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# ---- 载入版本参数 ----------------------------------------------------------
ENV_FILE=""
for f in "$SCRIPT_DIR/.env.cluster" "$SCRIPT_DIR/.env.cluster.example"; do
  if [ -f "$f" ]; then ENV_FILE="$f"; break; fi
done
[ -n "$ENV_FILE" ] || die "缺少 cluster/.env.cluster(.example)"
c_info "使用环境文件: ${ENV_FILE#"$ROOT_DIR"/}"
set -a
# shellcheck source=/dev/null
. "$ENV_FILE"
set +a

SIGNOZ_VERSION="${SIGNOZ_VERSION:-v0.146.0}"
COLLECTOR_VERSION="${COLLECTOR_VERSION:-v0.144.14}"
CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION:-25.12.5}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
HAPROXY_VERSION="${HAPROXY_VERSION:-2.9-alpine}"

# ---- 架构 ----------------------------------------------------------------
HOST_ARCH="$(uname -m)"
case "$HOST_ARCH" in
  x86_64|amd64)  HOST_ARCH="amd64" ;;
  aarch64|arm64) HOST_ARCH="arm64" ;;
  *) die "不支持的本机架构: $HOST_ARCH" ;;
esac

if [ -z "$ARCH" ]; then
  ARCH="$HOST_ARCH"
else
  case "$ARCH" in
    x86_64|amd64) ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    *) die "不支持的 --arch: $ARCH（可选 amd64 / arm64）" ;;
  esac
fi

# ---- 依赖与文件检查 --------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "未找到 docker，请在联网打包机安装 Docker"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon（未启动或当前用户无权限）"

for f in cluster/docker-stack.cluster.yaml cluster/install-cluster.sh \
         cluster/haproxy.cfg cluster/README.md cluster/.env.cluster.example \
         config/ingester/ingester.yaml config/ingester/opamp.yaml \
         cluster/config/clickhouse/cluster-0.xml cluster/config/clickhouse/cluster-1.xml \
         cluster/config/clickhouse/users.xml cluster/config/clickhouse/functions.yaml \
         cluster/config/keeper/keeper-0.yaml cluster/config/keeper/keeper-1.yaml \
         cluster/config/keeper/keeper-2.yaml \
         cluster/config/ingester/ingester.yaml \
         assets/histogram-quantile/histogram-quantile-linux-amd64 \
         assets/histogram-quantile/histogram-quantile-linux-arm64; do
  [ -f "$f" ] || die "缺少必要文件: $f"
done

HQ="assets/histogram-quantile/histogram-quantile-linux-${ARCH}"
[ -f "$HQ" ] || die "缺少 ${ARCH} 架构的 histogram-quantile：$HQ"

IMAGE_PLATFORM="linux/${ARCH}"
IMAGES=(
  "signoz/signoz:${SIGNOZ_VERSION}"
  "signoz/signoz-otel-collector:${COLLECTOR_VERSION}"
  "clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}"
  "clickhouse/clickhouse-keeper:${CLICKHOUSE_VERSION}"
  "postgres:${POSTGRES_VERSION}"
  "haproxy:${HAPROXY_VERSION}"
)

echo "=============================================================="
echo " SigNoz 集群离线包制作"
echo " 目标架构 : ${ARCH}（打包机 ${HOST_ARCH}）"
echo " 拓扑     : 1 shard x 2 replicas + 3 Keeper + HAProxy"
echo " SigNoz   : ${SIGNOZ_VERSION}"
echo " Collector: ${COLLECTOR_VERSION}"
echo " ClickHouse: ${CLICKHOUSE_VERSION}"
echo " HAProxy  : ${HAPROXY_VERSION}"
echo "=============================================================="

# ---- 拉取镜像 --------------------------------------------------------------
c_step "拉取镜像（目标平台 ${IMAGE_PLATFORM}）"
for img in "${IMAGES[@]}"; do
  c_info "docker pull ${img}"
  _pulled="no"
  for attempt in 1 2 3; do
    if docker pull --platform "$IMAGE_PLATFORM" "$img"; then
      _pulled="yes"
      break
    fi
    c_warn "拉取失败（第 ${attempt}/3 次），10 秒后重试: ${img}"
    sleep 10
  done
  [ "$_pulled" = "yes" ] || die "镜像拉取连续失败: ${img}（检查网络或 Docker Hub 限流）"
done

for img in "${IMAGES[@]}"; do
  docker image inspect "$img" >/dev/null 2>&1 || die "镜像拉取后仍不存在: $img"
  _img_arch="$(docker image inspect -f '{{.Architecture}}' "$img")"
  [ "$_img_arch" = "$ARCH" ] || die "镜像架构不匹配: ${img} 实际为 ${_img_arch}，期望 ${ARCH}"
done

# ---- 导出镜像 --------------------------------------------------------------
c_step "导出镜像"
mkdir -p "$OUT_DIR"
IMG_TAR="${OUT_DIR}/signoz-cluster-images-${SIGNOZ_VERSION}-${ARCH}.tar"
docker save -o "$IMG_TAR" "${IMAGES[@]}"
if command -v pigz >/dev/null 2>&1; then
  pigz -1 -f "$IMG_TAR"
else
  gzip -1 -f "$IMG_TAR"
fi
IMG_GZ="${IMG_TAR}.gz"
c_info "镜像包: ${IMG_GZ}（$(du -h "$IMG_GZ" | cut -f1)）"

# ---- 组装离线包 ------------------------------------------------------------
c_step "组装集群离线包"
PKG="signoz-cluster-offline-${SIGNOZ_VERSION}-${ARCH}"
STAGE="${OUT_DIR}/${PKG}"
rm -rf "$STAGE"
mkdir -p "${STAGE}/images"

cp -a cluster/config "$STAGE/config"
cp -a assets "$STAGE/assets"
install -m 0644 cluster/docker-stack.cluster.yaml "$STAGE/docker-stack.cluster.yaml"
install -m 0755 cluster/install-cluster.sh "$STAGE/install-cluster.sh"
chmod 0755 "$STAGE/install-cluster.sh" 2>/dev/null || true
install -m 0644 cluster/haproxy.cfg "$STAGE/haproxy.cfg"
install -m 0644 cluster/.env.cluster.example "$STAGE/.env.cluster.example"
install -m 0644 cluster/README.md "$STAGE/README.md"
cp "$IMG_GZ" "${STAGE}/images/"

{
  for img in "${IMAGES[@]}"; do
    printf '%s\n' "$img"
  done
} > "${STAGE}/images/IMAGES.txt"

{
  echo "SigNoz cluster offline deployment bundle"
  echo "Built at     : $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Built on     : $(uname -s) $(uname -m) $(uname -r)"
  echo "Target arch  : ${ARCH}"
  echo "Topology     : 1 shard x 2 ClickHouse replicas, 3 Keeper, HAProxy, 2 SigNoz, 2 Collector"
  echo "SigNoz       : ${SIGNOZ_VERSION}"
  echo "Collector    : ${COLLECTOR_VERSION}"
  echo "ClickHouse   : ${CLICKHOUSE_VERSION}"
  echo "Postgres     : ${POSTGRES_VERSION}"
  echo "HAProxy      : ${HAPROXY_VERSION}"
  echo "Images       :"
  for img in "${IMAGES[@]}"; do echo "  - ${img}"; done
} > "${STAGE}/BUILD-INFO.txt"

tar -C "$OUT_DIR" -czf "${OUT_DIR}/${PKG}.tar.gz" "$PKG"
rm -rf "$STAGE"
rm -f "$IMG_GZ"

PKG_FILE="${OUT_DIR}/${PKG}.tar.gz"

# ---- 校验和 ----------------------------------------------------------------
c_step "完成"
echo "  集群离线包 : ${PKG_FILE}"
echo "  大小       : $(du -h "$PKG_FILE" | cut -f1)"
if command -v sha256sum >/dev/null 2>&1; then
  _sha="$(sha256sum "$PKG_FILE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  _sha="$(shasum -a 256 "$PKG_FILE" | awk '{print $1}')"
else
  _sha=""
fi
if [ -n "$_sha" ]; then
  echo "  SHA256     : ${_sha}"
  printf '%s  %s\n' "$_sha" "$(basename "$PKG_FILE")" > "${PKG_FILE}.sha256"
fi
cat <<EOF

下一步（详见包内 README.md）：
  1) 把集群离线包复制到每个节点，解压到 /opt/signoz-cluster
  2) 每个节点： sudo bash ./install-cluster.sh --prepare
  3) node1 初始化 Swarm，其他节点加入
  4) manager： sudo bash ./install-cluster.sh --deploy --nodes node1,node2,node3
EOF
