#!/bin/bash
# ==========================================================
# 脚本名称: install.sh (动态模块化终极引导入口)
# 核心功能: 权限鉴定、沙盒创建、Ctrl+C 熔断保护、动态版本嗅探
# ==========================================================

if [ "$EUID" -ne 0 ]; then
  echo -e "\033[31m❌ 权限被拒绝: 部署 IP-Sentinel 需要最高系统权限。\033[0m"
  echo -e "💡 请切换到 root 用户 (执行 su root 或 sudo -i) 后重新运行指令。"
  exit 1
fi

SECURE_TMP=$(mktemp -d /tmp/ips_install.XXXXXX)

cleanup_and_exit() {
    echo -e "\n\n\033[33m⚠️ 检测到中断信号 (Ctrl+C)，安装操作已被手动中止。\033[0m"
    echo -e "🧹 正在清理临时沙盒文件..."
    rm -rf "$SECURE_TMP" 2>/dev/null
    exit 1
}
trap cleanup_and_exit INT QUIT TERM
trap 'rm -rf "$SECURE_TMP" 2>/dev/null' EXIT HUP

REPO_RAW_URL="https://raw.githubusercontent.com/jasper-khan/IP-Sentinel/main"

# ----------------------------------------------------------
# [核心架构升级] 动态嗅探云端真理之源 (SSOT)
# ----------------------------------------------------------
TARGET_VERSION=$( (curl -fsSL --connect-timeout 5 --retry 2 "${REPO_RAW_URL}/version.txt?t=$(date +%s)" || curl -4 -fsSL --connect-timeout 5 --retry 2 "${REPO_RAW_URL}/version.txt?t=$(date +%s)") 2>/dev/null | grep "^AGENT_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
TARGET_VERSION=${TARGET_VERSION:-"4.3.1"}

echo -e "\n⏳ 正在拉取 IP-Sentinel v${TARGET_VERSION} 安装模块引擎..."

# ----------------------------------------------------------
# [V3 安全修复] 供应链完整性门禁：下载的引擎脚本必须与仓库
# MANIFEST.sha256 锁定哈希一致，否则拒绝以 root 执行。
# (bash -n 只是防截断的附加检查，不构成内容校验)
# ----------------------------------------------------------
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/MANIFEST.sha256?t=$(date +%s)" -o "${SECURE_TMP}/MANIFEST.sha256" 2>/dev/null

if [ -s "${SECURE_TMP}/MANIFEST.sha256" ]; then
    MANIFEST_EXPECTED=$(awk '$2 == "install/build_agent.sh" {print $1}' "${SECURE_TMP}/MANIFEST.sha256")
fi

curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/build_agent.sh?t=$(date +%s)" -o "${SECURE_TMP}/build_agent.sh"

if [ ! -s "${SECURE_TMP}/build_agent.sh" ]; then
    echo -e "\033[31m❌ 致命错误：核心安装引擎拉取失败！网络阻断或 GitHub Raw 异常。\033[0m"
    exit 1
fi

# [完整性熔断] 无清单或哈希不匹配 → 拒绝执行
MANIFEST_ACTUAL=$(sha256sum "${SECURE_TMP}/build_agent.sh" | awk '{print $1}')
if [ -z "$MANIFEST_EXPECTED" ] || [ "$MANIFEST_EXPECTED" != "$MANIFEST_ACTUAL" ]; then
    echo -e "\033[31m❌ 供应链熔断：安装引擎哈希与 MANIFEST.sha256 不符 (或清单缺失)。\033[0m"
    echo -e "\033[31m   可能原因：下载被劫持/污染，或仓库发布流程遗漏清单。已拒绝执行。\033[0m"
    exit 1
fi
if ! bash -n "${SECURE_TMP}/build_agent.sh"; then
    echo -e "\033[31m❌ 安装引擎语法校验失败，疑似下载截断。已拒绝执行。\033[0m"
    exit 1
fi

export SECURE_TMP
export REPO_RAW_URL
export TARGET_VERSION

chmod +x "${SECURE_TMP}/build_agent.sh"
bash "${SECURE_TMP}/build_agent.sh"

exit $?
