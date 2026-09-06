#!/bin/bash

# ==========================================================
# 脚本名称: updater.sh (系统维护巡检)
# 核心功能: 探针完整性巡检 + 日志瘦身
# [引擎代管] 本地 curl 养护引擎已移除——本脚本不再做任何运行时下载
# (UA 池/关键词/区域模板的历史同步逻辑已删除;养护行为与指纹由
#  Master 的 Camoufox 浏览器引擎执行)
# ==========================================================

INSTALL_DIR="/opt/ip_sentinel"
CONFIG_FILE="${INSTALL_DIR}/config.conf"

# --- [底层数据链装载] ---
if [ ! -f "$CONFIG_FILE" ]; then
    exit 1
fi
source "$CONFIG_FILE"

# --- [全局态势日志系统] ---
log() {
    local local_ver="${AGENT_VERSION:-未知}"

    mkdir -p "${INSTALL_DIR}/logs"

    local core_msg=$(printf "[v%-5s] [%-5s] [%-7s] [%s] %s" "$local_ver" "$2" "$1" "$REGION_CODE" "$3")
    # 强制剔除节点宿主机本地时差，严格对齐指挥部 UTC 基准
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] $core_msg" >> "$LOG_FILE"

    if command -v logger >/dev/null 2>&1; then
        logger -t ip-sentinel "$core_msg"
    else
        echo "$core_msg"
    fi
}

log "Updater" "INFO " "========== 触发后台系统维护巡检 =========="

# ==========================================================
# [供应链防线] 探针 (ip.sh) 已 vendor 进仓库并锁定 SHA-256，
# 仅随仓库受控发布整体更新，不参与每日热数据同步。
# 运行时校验由 mod_quality.sh 的完整性门禁执行。
# ==========================================================
PROBE_SCRIPT="${INSTALL_DIR}/data/probe/ip.sh"
PROBE_SHA_FILE="${INSTALL_DIR}/data/probe/ip.sh.sha256"
if [ -s "$PROBE_SCRIPT" ] && [ -s "$PROBE_SHA_FILE" ]; then
    EXPECTED_PROBE_SHA=$(tr -d '[:space:]' < "$PROBE_SHA_FILE")
    ACTUAL_PROBE_SHA=$(sha256sum "$PROBE_SCRIPT" 2>/dev/null | awk '{print $1}')
    if [ -n "$EXPECTED_PROBE_SHA" ] && [ "$EXPECTED_PROBE_SHA" != "$ACTUAL_PROBE_SHA" ]; then
        log "Updater" "WARN " "❌ 本地探针哈希与锁定值不符 (疑遭篡改)，请重新安装修复！"
    fi
else
    log "Updater" "WARN " "❌ 本地探针或哈希清单缺失，质量探测将中止，请重新安装修复！"
fi

# ==========================================================
# [空间瘦身] 长效健康清理与爆栈预防机制
# ==========================================================
if [ -f "$LOG_FILE" ]; then
    tail -n 2000 "$LOG_FILE" > "${LOG_FILE}.tmp"
    mv "${LOG_FILE}.tmp" "$LOG_FILE"
    log "Updater" "INFO " "🧹 系统日志已完成定期清理瘦身 (保留最新 2000 行)"
fi

log "Updater" "INFO " "========== 系统维护巡检结束 =========="
