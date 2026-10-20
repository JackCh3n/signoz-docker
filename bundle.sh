#!/usr/bin/env bash
# =============================================================================
# SigNoz 离线包制作脚本（在“能联网、有 Docker”的机器上执行）
#
# 做的事
#  1. 按 .env 中固定的版本拉取 5 个镜像
#  2. docker save 成一个镜像包（按目标架构）
#  3. 连同 compose、配置、histogram-quantile 二进制、安装脚本打成一个离线包
#
# 用法
#  ./bundle.sh                          # 本机架构
#  ./bundle.sh --arch arm64             # 为 ARM64（鲲鹏/麒麟）打包
#  ./bundle.sh --with-java-agent        # 额外打包 OTel Java Agent
#  ./bundle.sh --output /data/signoz    # 自定义输出目录
#
# 产物
#  dist/signoz-offline-<版本>-<架构>.tar.gz
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

OUT_DIR="$SCRIPT_DIR/dist"
ARCH=""
WITH_JAVA_AGENT="no"

c_info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
c_warn() { printf '\033[33m[警告]\033[0m %s\n' "$*"; }
c_err()  { printf '\033[31m[错误]\033[0m %s\n' "$*" >&2; }
c_step() { printf '\n\033[36m===> %s\033[0m\n' "$*"; }
die()    { c_err "$*"; exit 1; }

usage() {
  sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)            ARCH="${2:?--arch 需要参数}"; shift 2 ;;
    --with-java-agent) WITH_JAVA_AGENT="yes"; shift ;;
    --output)          OUT_DIR="${2:?--output 需要参数}"; shift 2 ;;
    -h|--help)         usage ;;
    *) die "未知参数: $1（用 --help 查看用法）" ;;
  esac
done

# ---- 载入版本参数 ----------------------------------------------------------
if [ -f .env ]; then
  c_info "使用 .env 中的版本参数"
  set -a
  # shellcheck source=/dev/null
  . ./.env
  set +a
elif [ -f .env.example ]; then
  c_info "未找到 .env，使用 .env.example 默认值"
  set -a
  # shellcheck source=/dev/null
  . ./.env.example
  set +a
else
  die "缺少 .env / .env.example，无法确定镜像版本"
fi

SIGNOZ_VERSION="${SIGNOZ_VERSION:-v0.146.0}"
COLLECTOR_VERSION="${COLLECTOR_VERSION:-v0.144.14}"
CLICKHOUSE_VERSION="${CLICKHOUSE_VERSION:-25.12.5}"
POSTGRES_VERSION="${POSTGRES_VERSION:-16}"
OTEL_JAVAAGENT_VERSION="${OTEL_JAVAAGENT_VERSION:-v2.32.0}"

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
    x86_64)  ARCH="amd64" ;;
    aarch64|arm64) ARCH="arm64" ;;
    amd64)   ARCH="amd64" ;;
    *) die "不支持的 --arch: $ARCH（可选 amd64 / arm64）" ;;
  esac
fi

# ---- 依赖检查 ------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "未找到 docker，请在联网打包机安装 Docker"
docker info >/dev/null 2>&1 || die "无法连接 Docker daemon（未启动或当前用户无权限）"

for f in docker-compose.yaml install.sh .env.example README.md \
         config/ingester/ingester.yaml config/ingester/opamp.yaml \
         config/telemetrykeeper/clickhousekeeper/keeper-0.yaml \
         config/telemetrystore/clickhouse/config-0-0.yaml \
         config/telemetrystore/clickhouse/functions.yaml; do
  [ -f "$f" ] || die "缺少必要文件: $f"
done

HQ="assets/histogram-quantile/histogram-quantile-linux-${ARCH}"
[ -f "$HQ" ] || die "缺少 ${ARCH} 架构的 histogram-quantile：$HQ"

IMAGE_AGENT=""
case "$ARCH" in
  amd64) IMAGE_AGENT="linux/amd64" ;;
  arm64) IMAGE_AGENT="linux/arm64" ;;
esac

IMAGES=(
  "signoz/signoz:${SIGNOZ_VERSION}"
  "signoz/signoz-otel-collector:${COLLECTOR_VERSION}"
  "clickhouse/clickhouse-server:${CLICKHOUSE_VERSION}"
  "clickhouse/clickhouse-keeper:${CLICKHOUSE_VERSION}"
  "postgres:${POSTGRES_VERSION}"
)

fetch() {
  _url="$1"; _dst="$2"
  if command -v curl >/dev/null 2>&1; then
    curl -fL --retry 3 --connect-timeout 20 -o "$_dst" "$_url"
  elif command -v wget >/dev/null 2>&1; then
    wget -O "$_dst" "$_url"
  else
    die "需要 curl 或 wget 下载文件"
  fi
}

echo "=============================================================="
echo " SigNoz 离线包制作"
echo " 目标架构 : ${ARCH}（打包机 ${HOST_ARCH}）"
echo " SigNoz   : ${SIGNOZ_VERSION}"
echo " Collector: ${COLLECTOR_VERSION}"
echo " ClickHouse: ${CLICKHOUSE_VERSION}"
echo "=============================================================="

# ---- 可选：Java Agent -----------------------------------------------------
if [ "$WITH_JAVA_AGENT" = "yes" ]; then
  c_step "下载 OpenTelemetry Java Agent ${OTEL_JAVAAGENT_VERSION}"
  mkdir -p assets/otel-javaagent
  _jar="assets/otel-javaagent/opentelemetry-javaagent.jar"
  fetch "https://github.com/open-telemetry/opentelemetry-java-instrumentation/releases/download/${OTEL_JAVAAGENT_VERSION}/opentelemetry-javaagent.jar" "$_jar"
  _size="$(wc -c < "$_jar" | tr -d ' ')"
  [ "$_size" -gt 1000000 ] || die "Java Agent 下载不完整（${_size} 字节）"
  c_info "已下载: ${_jar}"
fi

# ---- 拉取镜像 ------------------------------------------------------------
c_step "拉取镜像（目标平台 ${IMAGE_AGENT}）"
for img in "${IMAGES[@]}"; do
  c_info "docker pull ${img}"
  _pulled="no"
  for attempt in 1 2 3; do
    if docker pull --platform "$IMAGE_AGENT" "$img"; then
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
  [ "$_img_arch" = "$ARCH" ] || die "镜像架构不匹配: ${img} 实际为 ${_img_arch}，期望 ${ARCH}（镜像源可能忽略了 --platform）"
done

# ---- 导出镜像 ------------------------------------------------------------
c_step "导出镜像"
mkdir -p "$OUT_DIR"
IMG_TAR="${OUT_DIR}/signoz-images-${SIGNOZ_VERSION}-${ARCH}.tar"
docker save -o "$IMG_TAR" "${IMAGES[@]}"
# pigz 可用时多线程压缩；CI 上 2 GB 级别的 tar 用单线程 gzip 会慢很多
if command -v pigz >/dev/null 2>&1; then
  pigz -1 -f "$IMG_TAR"
else
  gzip -1 -f "$IMG_TAR"
fi
IMG_GZ="${IMG_TAR}.gz"
c_info "镜像包: ${IMG_GZ}（$(du -h "$IMG_GZ" | cut -f1)）"

# ---- 组装离线包 ----------------------------------------------------------
c_step "组装离线包"
PKG="signoz-offline-${SIGNOZ_VERSION}-${ARCH}"
STAGE="${OUT_DIR}/${PKG}"
rm -rf "$STAGE"
mkdir -p "${STAGE}/images"
cp docker-compose.yaml install.sh .env.example README.md "$STAGE/"
cp -a config "$STAGE/"
cp -a assets "$STAGE/"
cp "$IMG_GZ" "${STAGE}/images/"

{
  for img in "${IMAGES[@]}"; do
    printf '%s\n' "$img"
  done
} > "${STAGE}/images/IMAGES.txt"

{
  echo "SigNoz offline deployment bundle"
  echo "Built at     : $(date '+%Y-%m-%d %H:%M:%S %z')"
  echo "Built on     : $(uname -s) $(uname -m) $(uname -r)"
  echo "Target arch  : ${ARCH}"
  echo "SigNoz       : ${SIGNOZ_VERSION}"
  echo "Collector    : ${COLLECTOR_VERSION}"
  echo "ClickHouse   : ${CLICKHOUSE_VERSION}"
  echo "Postgres     : ${POSTGRES_VERSION}"
  echo "Java agent   : $([ "$WITH_JAVA_AGENT" = "yes" ] && echo "${OTEL_JAVAAGENT_VERSION}" || echo "not bundled")"
  echo "Images       :"
  for img in "${IMAGES[@]}"; do echo "  - ${img}"; done
} > "${STAGE}/BUILD-INFO.txt"

tar -C "$OUT_DIR" -czf "${OUT_DIR}/${PKG}.tar.gz" "$PKG"
rm -rf "$STAGE"
# 镜像 tar.gz 已装进离线包，删除 dist 根目录下的中间件，否则 CI 会同时留下两份约 1 GB 的文件
rm -f "$IMG_GZ"

PKG_FILE="${OUT_DIR}/${PKG}.tar.gz"

# ---- 校验和 --------------------------------------------------------------
c_step "完成"
echo "  离线包 : ${PKG_FILE}"
echo "  大小   : $(du -h "$PKG_FILE" | cut -f1)"
if command -v sha256sum >/dev/null 2>&1; then
  _sha="$(sha256sum "$PKG_FILE" | awk '{print $1}')"
elif command -v shasum >/dev/null 2>&1; then
  _sha="$(shasum -a 256 "$PKG_FILE" | awk '{print $1}')"
else
  _sha=""
fi
[ -n "$_sha" ] && { echo "  SHA256 : ${_sha}"; printf '%s  %s\n' "$_sha" "$(basename "$PKG_FILE")" > "${PKG_FILE}.sha256"; }
echo
echo "下一步："
echo "  1) 将 ${PKG_FILE} 传入内网目标机"
echo "  2) tar xzf $(basename "$PKG_FILE") && cd ${PKG}"
echo "  3) ./install.sh --check   # 预检"
echo "  4) ./install.sh           # 导入镜像并启动"
