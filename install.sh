#!/bin/bash
# ==========================================================
# 脚本名称: install.sh (Agent 引导入口)
# 核心功能: 权限鉴定、拉取唯一权威安装器 (core/install.sh) 并做
#           MANIFEST.sha256 供应链门禁，Ctrl+C 熔断保护
# 说明: 本 fork 已收敛为单一安装链 —— core/install.sh 是 Agent
#       安装的唯一实现 (新装/升级/重注册/卸载全在其内)
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
# [V3 供应链门禁] 安装器本体必须与 MANIFEST.sha256 锁定哈希一致
# ----------------------------------------------------------
curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/MANIFEST.sha256?t=$(date +%s)" -o "${SECURE_TMP}/MANIFEST.sha256" 2>/dev/null

if [ -s "${SECURE_TMP}/MANIFEST.sha256" ]; then
    MANIFEST_EXPECTED=$(awk '$2 == "core/install.sh" {print $1}' "${SECURE_TMP}/MANIFEST.sha256")
fi

curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/core/install.sh?t=$(date +%s)" -o "${SECURE_TMP}/install_core.sh"

if [ ! -s "${SECURE_TMP}/install_core.sh" ]; then
    echo -e "\033[31m❌ 致命错误：核心安装引擎拉取失败！网络阻断或 GitHub Raw 异常。\033[0m"
    exit 1
fi

MANIFEST_ACTUAL=$(sha256sum "${SECURE_TMP}/install_core.sh" | awk '{print $1}')
if [ -z "$MANIFEST_EXPECTED" ] || [ "$MANIFEST_EXPECTED" != "$MANIFEST_ACTUAL" ]; then
    echo -e "\033[31m❌ 供应链熔断：安装引擎哈希与 MANIFEST.sha256 不符 (或清单缺失)。\033[0m"
    echo -e "\033[31m   可能原因：下载被劫持/污染，或仓库发布流程遗漏清单。已拒绝执行。\033[0m"
    exit 1
fi
if ! bash -n "${SECURE_TMP}/install_core.sh"; then
    echo -e "\033[31m❌ 安装引擎语法校验失败，疑似下载截断。已拒绝执行。\033[0m"
    exit 1
fi

chmod +x "${SECURE_TMP}/install_core.sh"
exec bash "${SECURE_TMP}/install_core.sh"
