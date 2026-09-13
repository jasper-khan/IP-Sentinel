#!/bin/bash
# ==========================================================
# 脚本名称: install_master.sh (动态模块化终极引导入口)
# 核心功能: 极简引导入口。包含 Ctrl+C 优雅中断，动态版本嗅探
# ==========================================================

cleanup_and_exit() {
    echo -e "\n\n\033[33m⚠️ 检测到中断信号 (Ctrl+C)，安装操作已被手动中止。\033[0m"
    echo -e "🧹 正在清理临时沙盒文件..."
    exit 1
}
trap cleanup_and_exit INT QUIT TERM
trap 'if [ -f "${SECURE_TMP}/MASTER_ROLLBACK_REQUIRED" ]; then echo "⚠️ 回滚备份已保留: ${SECURE_TMP}"; else rm -rf "$SECURE_TMP" 2>/dev/null; fi' EXIT HUP

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

SECURE_TMP=$(mktemp -d /tmp/ips_master_install.XXXXXX)
REPO_MAIN_URL="https://raw.githubusercontent.com/jasper-khan/IP-Sentinel/main"
REPO_RAW_URL="$REPO_MAIN_URL"

# ----------------------------------------------------------
# [可用性] CDN 间歇 404 重试函数
# curl --retry 不重试 404 (视为永久错误), 但 raw.githubusercontent 的
# 间歇 404 实为瞬时故障 — 必须 shell 级循环 (实测 5 次内必过)
# ----------------------------------------------------------
fetch_retry() {
    local url="$1" out="$2" i
    for i in 1 2 3 4 5; do
        curl -fsSL --connect-timeout 10 "${url}" -o "$out" 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

# ----------------------------------------------------------
# [版本锁定] OTA 调用方传入的版本优先; 兼容旧调用方时只从 main
# 确定一次版本, 随即将所有后续下载固定到对应 fork tag。
# ----------------------------------------------------------
TARGET_VERSION="${OTA_TARGET_VERSION:-}"
if [ -z "$TARGET_VERSION" ]; then
    TARGET_VERSION=$( (curl -fsSL --connect-timeout 5 --retry 2 "${REPO_MAIN_URL}/version.txt?t=$(date +%s)" || curl -4 -fsSL --connect-timeout 5 --retry 2 "${REPO_MAIN_URL}/version.txt?t=$(date +%s)") 2>/dev/null | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
fi

if ! [[ "$TARGET_VERSION" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    echo -e "\033[31m❌ 无法确定有效 Master 版本，安装已取消。\033[0m"
    exit 1
fi

REPO_RAW_URL="${REPO_MAIN_URL%/main}/v${TARGET_VERSION}-fork"

echo -e "\n⏳ 正在拉取 IP-Sentinel Master v${TARGET_VERSION} 安装引擎..."

# ----------------------------------------------------------
# [V3 安全修复] 供应链完整性门禁 (与 Agent 引导入口同构)
# ----------------------------------------------------------
fetch_retry "${REPO_RAW_URL}/MANIFEST.sha256?t=$(date +%s)" "${SECURE_TMP}/MANIFEST.sha256"

if [ -s "${SECURE_TMP}/MANIFEST.sha256" ]; then
    MANIFEST_EXPECTED=$(awk '$2 == "install/build_master.sh" {print $1}' "${SECURE_TMP}/MANIFEST.sha256")
fi

fetch_retry "${REPO_RAW_URL}/install/build_master.sh?t=$(date +%s)" "${SECURE_TMP}/build_master.sh"

if [ ! -s "${SECURE_TMP}/build_master.sh" ]; then
    echo -e "\033[31m❌ 致命错误：中枢安装引擎拉取失败！网络阻断或 GitHub Raw 异常。\033[0m"
    exit 1
fi

# [完整性熔断] 无清单或哈希不匹配 → 拒绝执行
MANIFEST_ACTUAL=$(sha256sum "${SECURE_TMP}/build_master.sh" | awk '{print $1}')
if [ -z "$MANIFEST_EXPECTED" ] || [ "$MANIFEST_EXPECTED" != "$MANIFEST_ACTUAL" ]; then
    echo -e "\033[31m❌ 供应链熔断：安装引擎哈希与 MANIFEST.sha256 不符 (或清单缺失)。已拒绝执行。\033[0m"
    exit 1
fi
if ! bash -n "${SECURE_TMP}/build_master.sh"; then
    echo -e "\033[31m❌ 安装引擎语法校验失败，疑似下载截断。已拒绝执行。\033[0m"
    exit 1
fi

export SECURE_TMP
export REPO_RAW_URL
export TARGET_VERSION
export OTA_TARGET_VERSION="$TARGET_VERSION"

chmod +x "${SECURE_TMP}/build_master.sh"
bash "${SECURE_TMP}/build_master.sh"

exit $?
