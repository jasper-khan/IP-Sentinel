#!/bin/bash
# ==========================================================
# 模块名称: master_setup.sh
# 核心功能: Master 环境清洗、令牌交互、SQLite 建库、守护进程注入与结果呈现
# ==========================================================

# 预检部分需要单独定制，因为 Master 有专属横幅
do_master_env_precheck() {
    echo -e "\n======================================"
    echo -e "📊 \033[36mIP-Sentinel 中枢靶机环境侦测\033[0m"
    echo -e "--------------------------------------"
    echo -e "OS 架构   : $(get_os_info)"
    echo -e "虚拟化    : $(get_virt_info)"
    if is_systemd; then
        echo -e "Init 系统 : systemd ✅"
    else
        echo -e "Init 系统 : 非 systemd ⚠️ (将自动降维至看门狗模式)"
    fi
    echo -e "======================================\n"
    sleep 1
}

do_fetch_master_version() {
    if [ -z "${TARGET_VERSION:-}" ]; then
        echo -e "\033[31m❌ Master 版本未锁定，拒绝继续安装。\033[0m"
        return 1
    fi

    MASTER_DIR="/opt/ip_sentinel_master"
    DB_FILE="${MASTER_DIR}/sentinel.db"

    echo "========================================================"
    echo "      🧠 欢迎使用 IP-Sentinel Master (控制中枢) v${TARGET_VERSION}"
    echo "========================================================"
}

do_master_handle_menu() {
    if [ "$SILENT_MASTER_OTA" == "true" ]; then
        echo -e "\n⏳ [OTA] 中枢重构指令已确认，正在剥离控制台交互..."
        ACTION_CHOICE=1
        UPGRADE_MODE="true"
        KEEP_DB="true"
        
        if [ -f "${MASTER_DIR}/master.conf" ]; then
            source "${MASTER_DIR}/master.conf"
        fi
        echo -e "\033[32m✅ 已激活 [中枢静默重构模式]，即将无损覆写内核...\033[0m"
    else
        echo -e "\n请选择操作:"
        echo "  1) 🚀 部署 Master 控制中枢"
        echo "  2) 🗑️ 一键卸载 Master 中枢"
        read -p "请输入选择 [1-2] (默认1): " ACTION_CHOICE

        ACTION_CHOICE=${ACTION_CHOICE:-1}

        if [ "$ACTION_CHOICE" == "2" ]; then
            echo -e "\n⏳ 正在拉取卸载程序..."
            curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/master/uninstall_master.sh" -o "${SECURE_TMP}/uninstall_master.sh"
            chmod +x "${SECURE_TMP}/uninstall_master.sh"
            bash "${SECURE_TMP}/uninstall_master.sh"
            rm -f "/tmp/uninstall_master.sh"
            exit 0
        fi

        UPGRADE_MODE="false"
        KEEP_DB="true"

        if [ "$ACTION_CHOICE" == "1" ] && [ -f "${MASTER_DIR}/master.conf" ]; then
            echo -e "\n\033[33m💡 司令部雷达提示：检测到本机已部署过 Master 中枢。\033[0m"
            read -p "👉 是否按原配置直接进行平滑升级？(y/n, 默认y): " UPGRADE_CHOICE
            if [[ -z "$UPGRADE_CHOICE" || "$UPGRADE_CHOICE" =~ ^[Yy]$ ]]; then
                UPGRADE_MODE="true"
                read -p "👉 是否保留历史节点数据库 (SQLite)？(y/n, 默认y): " DB_CHOICE
                if [[ "$DB_CHOICE" =~ ^[Nn]$ ]]; then
                    KEEP_DB="false"
                fi
                
                source "${MASTER_DIR}/master.conf"
                
                echo -e "\033[32m✅ 已激活 [平滑升级模式]，版本已锚定为 v${TARGET_VERSION}...\033[0m"
            else
                echo -e "\033[33m🔄 您选择了重新配置，旧的中枢数据将被彻底抹除。\033[0m"
            fi
        fi
    fi
}

do_master_clean_env() {
    echo -e "\n⏳ 正在验证本地环境与数据..."

    if [ "$UPGRADE_MODE" == "true" ]; then
        if [ "$KEEP_DB" == "false" ]; then
            rm -f "$DB_FILE" 2>/dev/null
            echo -e "🗑️ 历史节点数据库已按指令清空。"
        else
            echo -e "📦 历史节点数据库 (SQLite) 已绝密保留。"
        fi
    else
        rm -rf "$MASTER_DIR" 2>/dev/null
    fi
    mkdir -p "$MASTER_DIR"
}

do_master_config() {
    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n[2/4] 配置控制中枢机器人:"
        read -p "请输入 Telegram Bot Token: " TG_TOKEN
        
        echo -e "\n请选择您的部署环境身份:"
        echo "  1) 🛡️ 私有独立中枢 (默认推荐，保留完整 OTA 遥控权限)"
        echo "  2) ☁️ 官方公共网关 (面向大众服务，将强制物理隐藏全局 OTA 按钮防滥用)"
        read -p "请输入选择 [1-2] (默认1): " GATEWAY_TYPE
        GATEWAY_TYPE=${GATEWAY_TYPE:-1}
        
        IS_OFFICIAL_GATEWAY="false"
        ENABLE_MASTER_OTA="false"
        if [ "$GATEWAY_TYPE" == "2" ]; then
            IS_OFFICIAL_GATEWAY="true"
            echo -e "\033[33m⚠️ 已开启官方公共网关模式，全舰队与司令部的 OTA 将被强制屏蔽。\033[0m"
        else
            echo -e "\n[2.1/4] 司令部自我进化授权"
            echo -e "💡 开启后，您可以在 TG 菜单一键将中枢核心系统热更新至最新版本。"
            read -p "是否允许司令部接收 OTA 重构指令？(y/n, 默认y): " M_OTA_CHOICE
            if [[ "$M_OTA_CHOICE" =~ ^[Nn]$ ]]; then
                ENABLE_MASTER_OTA="false"
                echo -e "🛡️ \033[33m已关闭司令部 OTA 权限，中枢内核未来仅支持 SSH 升级。\033[0m"
            else
                ENABLE_MASTER_OTA="true"
                echo -e "✅ \033[32m已开启司令部 OTA 权限，金蝉脱壳引信已挂载。\033[0m"
            fi
        fi

        MASTER_IP=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
        MASTER_HASH=$(echo "${MASTER_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
        MASTER_NODE="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${MASTER_HASH}"
        
        echo -e "\n[2.2/4] 司令部展示别名设定 (用于面板区分多台 VPS)"
        echo -e "💡 系统底层的不可变主键为: \033[33m${MASTER_NODE}\033[0m"
        read -p "请输入中枢展示别名 (如'美西主控机', 回车使用默认): " CUSTOM_MASTER_ALIAS

        if [ -n "$CUSTOM_MASTER_ALIAS" ]; then
            # 强制声明 UTF-8 环境，丢弃危险的 cut -c 字节切分，改用 Bash 原生字符切片防御中文乱码
            export LC_ALL=C.UTF-8 2>/dev/null || export LC_ALL=en_US.UTF-8 2>/dev/null || true
            CLEAN_ALIAS=$(echo "$CUSTOM_MASTER_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r')
            MASTER_NODE_NAME="${CLEAN_ALIAS:0:20}"
            [ -z "$MASTER_NODE_NAME" ] && MASTER_NODE_NAME="$MASTER_NODE"
        else
            MASTER_NODE_NAME="$MASTER_NODE"
        fi
        echo -e "✅ 已锁定司令部展示别名: \033[32m$MASTER_NODE_NAME\033[0m"

        cat > "${MASTER_DIR}/master.conf" << EOF
# IP-Sentinel Master 本地固化配置 (v${TARGET_VERSION})
MASTER_NODE_NAME="$MASTER_NODE_NAME"
TG_TOKEN="$TG_TOKEN"
DB_FILE="$DB_FILE"
MASTER_DIR="$MASTER_DIR"
IS_OFFICIAL_GATEWAY="$IS_OFFICIAL_GATEWAY"
ENABLE_MASTER_OTA="$ENABLE_MASTER_OTA"
EOF
    fi

    if [ "$UPGRADE_MODE" == "true" ]; then
        if ! grep -q "^IS_OFFICIAL_GATEWAY=" "${MASTER_DIR}/master.conf"; then
            echo "IS_OFFICIAL_GATEWAY=\"false\"" >> "${MASTER_DIR}/master.conf"
        fi
        if ! grep -q "^ENABLE_MASTER_OTA=" "${MASTER_DIR}/master.conf"; then
            echo "ENABLE_MASTER_OTA=\"false\"" >> "${MASTER_DIR}/master.conf"
        fi
        if ! grep -q "^MASTER_NODE_NAME=" "${MASTER_DIR}/master.conf"; then
            MASTER_IP=$( (curl -4 -s -m 3 api.ip.sb/ip || curl -4 -s -m 3 ifconfig.me) 2>/dev/null | tr -d '[:space:]' )
            MASTER_HASH=$(echo "${MASTER_IP:-127.0.0.1}" | md5sum | cut -c 1-4 | tr 'a-z' 'A-Z')
            MASTER_NODE_NAME="$(hostname | tr -cd 'a-zA-Z0-9' | cut -c 1-10)-${MASTER_HASH}"
            echo "MASTER_NODE_NAME=\"$MASTER_NODE_NAME\"" >> "${MASTER_DIR}/master.conf"
        fi
    fi
}

do_master_init_db() {
    echo -e "\n[3/4] 正在初始化 SQLite 数据库表结构..."
    sqlite3 "$DB_FILE" <<EOF
CREATE TABLE IF NOT EXISTS nodes (
    chat_id TEXT,
    node_name TEXT,
    agent_ip TEXT,
    agent_port TEXT,
    last_seen DATETIME DEFAULT CURRENT_TIMESTAMP,
    region TEXT DEFAULT 'UNKNOWN',
    node_alias TEXT,
    enable_google TEXT DEFAULT 'true',
    enable_trust TEXT DEFAULT 'true',
    enable_ota TEXT DEFAULT 'false',
    PRIMARY KEY(chat_id, node_name)
);

CREATE TABLE IF NOT EXISTS ip_trend_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_name TEXT,
    check_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    scam_score INTEGER,
    goog_status TEXT,
    nf_status TEXT,
    gpt_status TEXT
);
EOF
    echo "✅ 数据库创建成功: $DB_FILE"
    chmod 600 "${MASTER_DIR}/master.conf"
    chmod 600 "$DB_FILE"
}

do_master_stage_payloads() {
    echo -e "\n⏳ 正在预下载并校验新版司令部核心与引擎文件..."

    TMP_MASTER="${SECURE_TMP}/tg_master.sh"
    if ! curl -fsSL --connect-timeout 10 --retry 3 \
        "${REPO_RAW_URL}/master/tg_master.sh?t=$(date +%s)" -o "$TMP_MASTER" || [ ! -s "$TMP_MASTER" ]; then
        echo -e "\033[31m❌ 致命错误：中枢核心代码拉取失败！\033[0m"
        echo "🛡️ 防砖机制触发：旧版司令部仍在安全运行中。"
        return 1
    fi

    EXPECTED=$(awk '$2 == "master/tg_master.sh" {print $1}' "${SECURE_TMP}/MANIFEST.sha256" 2>/dev/null)
    ACTUAL=$(sha256sum "$TMP_MASTER" 2>/dev/null | awk '{print $1}')
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ] || ! bash -n "$TMP_MASTER"; then
        echo -e "\033[31m❌ 供应链熔断：中枢核心哈希与 MANIFEST.sha256 不符，拒绝执行。\033[0m"
        echo "🛡️ 防砖机制触发：旧版司令部仍在安全运行中。"
        return 1
    fi

    if ! do_engine_stage_files; then
        echo "🛡️ 防砖机制触发：引擎预下载失败，旧版司令部仍在安全运行中。"
        return 1
    fi
}

do_master_save_rollback() {
    MASTER_ROLLBACK_DIR="${SECURE_TMP}/master_rollback"
    mkdir -p "$MASTER_ROLLBACK_DIR" || return 1
    MASTER_SWAPPED="false"
    MASTER_SERVICE_STOPPED="false"
    MASTER_ROLLBACK_CORE="false"
    MASTER_ROLLBACK_CONFIG="false"

    if [ -f "${MASTER_DIR}/tg_master.sh" ]; then
        cp -p "${MASTER_DIR}/tg_master.sh" "${MASTER_ROLLBACK_DIR}/tg_master.sh" || return 1
        MASTER_ROLLBACK_CORE="true"
    fi
    if [ -f "${MASTER_DIR}/master.conf" ]; then
        cp -p "${MASTER_DIR}/master.conf" "${MASTER_ROLLBACK_DIR}/master.conf" || return 1
        MASTER_ROLLBACK_CONFIG="true"
    fi
}

do_master_deploy_core() {
    echo -e "\n[4/4] 正在部署已校验的新版司令部核心引擎..."

    if [ ! -s "${TMP_MASTER:-}" ]; then
        echo -e "\033[31m❌ 中枢核心未完成预下载，拒绝停止现有服务。\033[0m"
        return 1
    fi
    if ! do_master_save_rollback; then
        echo -e "\033[31m❌ 无法保存旧版司令部，拒绝进行替换。\033[0m"
        return 1
    fi

    echo "⏳ 新引擎校验通过，正在抹杀旧版守护进程..."
    if is_systemd; then
        systemctl kill --signal=SIGKILL ip-sentinel-master.service >/dev/null 2>&1 || true
        systemctl stop ip-sentinel-master.service >/dev/null 2>&1 || true
    fi
    pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true
    MASTER_SERVICE_STOPPED="true"

    if ! mv "$TMP_MASTER" "${MASTER_DIR}/tg_master.sh"; then
        echo -e "\033[31m❌ 新版司令部落位失败。\033[0m"
        return 1
    fi
    MASTER_SWAPPED="true"
    if ! chmod +x "${MASTER_DIR}/tg_master.sh"; then
        echo -e "\033[31m❌ 新版司令部权限设置失败。\033[0m"
        return 1
    fi

    if is_systemd; then
        echo "💡 检测到 Systemd 环境，正在部署原生守护服务..."
        
        cat > /etc/systemd/system/ip-sentinel-master.service << EOF
[Unit]
Description=IP-Sentinel Master Command Center Service
After=network.target

[Service]
Environment="PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
SyslogIdentifier=ip-sentinel
Type=simple
ExecStart=/bin/bash ${MASTER_DIR}/tg_master.sh
Restart=always
RestartSec=5
User=root
WorkingDirectory=${MASTER_DIR}
CPUSchedulingPolicy=idle
IOSchedulingClass=idle

[Install]
WantedBy=multi-user.target
EOF

        if ! systemctl daemon-reload || \
           ! systemctl enable --now ip-sentinel-master.service || \
           ! systemctl restart ip-sentinel-master.service || \
           ! systemctl is-active --quiet ip-sentinel-master.service; then
            echo -e "\033[31m❌ 新版司令部服务启动检查失败。\033[0m"
            return 1
        fi
        
        crontab -l 2>/dev/null | grep -v "tg_master.sh" | crontab - >/dev/null 2>&1 || true
    else
        echo "💡 未检测到 Systemd，回退到 Cron 看门狗调度模式..."
        crontab -l 2>/dev/null | grep -v "tg_master.sh" > "${SECURE_TMP}/cron_master" || true
        echo "* * * * * pgrep -f tg_master.sh >/dev/null || nohup bash ${MASTER_DIR}/tg_master.sh >/dev/null 2>&1 &" >> "${SECURE_TMP}/cron_master"
        [ -f "${SECURE_TMP}/cron_master" ] && crontab "${SECURE_TMP}/cron_master" 2>/dev/null
        
        if ! pgrep -f tg_master.sh >/dev/null 2>&1; then
            nohup bash "${MASTER_DIR}/tg_master.sh" >/dev/null 2>&1 & disown 2>/dev/null
        fi
        if ! pgrep -f tg_master.sh >/dev/null 2>&1; then
            echo -e "\033[31m❌ 新版司令部进程启动检查失败。\033[0m"
            return 1
        fi
    fi
}

do_master_finalize_version() {
    local conf="${MASTER_DIR}/master.conf"
    if [ ! -f "$conf" ]; then
        echo -e "\033[31m❌ 配置文件不存在，无法固化 Master 版本。\033[0m"
        return 1
    fi

    if grep -q "^MASTER_VERSION=" "$conf"; then
        sed -i "s/^MASTER_VERSION=.*/MASTER_VERSION=\"$TARGET_VERSION\"/" "$conf" || return 1
    else
        printf 'MASTER_VERSION="%s"\n' "$TARGET_VERSION" >> "$conf" || return 1
    fi
    if ! grep -Fqx "MASTER_VERSION=\"$TARGET_VERSION\"" "$conf"; then
        echo -e "\033[31m❌ Master 版本固化校验失败。\033[0m"
        return 1
    fi
    chmod 600 "$conf" || return 1

    if is_systemd; then
        if ! systemctl restart ip-sentinel-master.service >/dev/null 2>&1 || \
           ! systemctl is-active --quiet ip-sentinel-master.service; then
            echo -e "\033[31m❌ 版本固化后 Master 重启检查失败。\033[0m"
            return 1
        fi
    else
        pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true
        nohup bash "${MASTER_DIR}/tg_master.sh" >/dev/null 2>&1 & disown 2>/dev/null
        if ! pgrep -f tg_master.sh >/dev/null 2>&1; then
            echo -e "\033[31m❌ 版本固化后 Master 进程检查失败。\033[0m"
            return 1
        fi
    fi
    MASTER_VERSION="$TARGET_VERSION"
}

do_master_rollback() {
    echo -e "\033[33m⚠️ 升级后置步骤失败，正在恢复旧版司令部...\033[0m"
    if [ "${MASTER_SERVICE_STOPPED:-false}" != "true" ]; then
        echo "ℹ️ 旧版服务未停止，跳过回滚动作。"
        return 0
    fi
    ROLLBACK_FAILED="false"
    if is_systemd; then
        systemctl stop ip-sentinel-master.service ip-sentinel-engine.service ip-sentinel-tunnels.service >/dev/null 2>&1 || true
    else
        pkill -9 -f "tg_master.sh" >/dev/null 2>&1 || true
        pkill -9 -f "engine/scheduler.sh" >/dev/null 2>&1 || true
        pkill -9 -f "tunnel_manager.sh" >/dev/null 2>&1 || true
    fi

    if [ "${MASTER_ROLLBACK_CORE:-false}" = "true" ] && [ -f "${MASTER_ROLLBACK_DIR}/tg_master.sh" ]; then
        if ! cp -p "${MASTER_ROLLBACK_DIR}/tg_master.sh" "${MASTER_DIR}/tg_master.sh" || \
           ! chmod +x "${MASTER_DIR}/tg_master.sh"; then
            echo -e "\033[31m❌ 旧版司令部恢复失败。\033[0m"
            ROLLBACK_FAILED="true"
        fi
    elif [ "${MASTER_SWAPPED:-false}" = "true" ]; then
        if ! rm -f "${MASTER_DIR}/tg_master.sh"; then
            echo -e "\033[31m❌ 新版司令部清理失败。\033[0m"
            ROLLBACK_FAILED="true"
        fi
    fi
    if [ "${MASTER_ROLLBACK_CONFIG:-false}" = "true" ] && [ -f "${MASTER_ROLLBACK_DIR}/master.conf" ]; then
        if ! cp -p "${MASTER_ROLLBACK_DIR}/master.conf" "${MASTER_DIR}/master.conf" || \
           ! chmod 600 "${MASTER_DIR}/master.conf"; then
            echo -e "\033[31m❌ 旧版 Master 配置恢复失败。\033[0m"
            ROLLBACK_FAILED="true"
        fi
    fi

    if [ -n "${ENG_FILES:-}" ] && [ -d "${MASTER_DIR}/engine" ]; then
        for f in $ENG_FILES; do
            if [ -f "${MASTER_ROLLBACK_DIR}/engine_${f}" ]; then
                if ! cp -p "${MASTER_ROLLBACK_DIR}/engine_${f}" "${MASTER_DIR}/engine/${f}"; then
                    echo -e "\033[31m❌ 旧版引擎文件 ${f} 恢复失败。\033[0m"
                    ROLLBACK_FAILED="true"
                fi
            elif [ -f "${MASTER_ROLLBACK_DIR}/engine_${f}.missing" ]; then
                if ! rm -f "${MASTER_DIR}/engine/${f}"; then
                    echo -e "\033[31m❌ 新版引擎文件 ${f} 清理失败。\033[0m"
                    ROLLBACK_FAILED="true"
                fi
            fi
        done
    fi

    if [ "$ROLLBACK_FAILED" = "true" ]; then
        : > "${SECURE_TMP}/MASTER_ROLLBACK_REQUIRED"
        echo -e "\033[31m❌ 回滚未完全完成，已保留本地备份: ${MASTER_ROLLBACK_DIR}\033[0m"
        return 1
    fi

    if is_systemd; then
        if [ "${MASTER_SERVICE_STOPPED:-false}" = "true" ]; then
            if ! systemctl daemon-reload >/dev/null 2>&1 || \
               ! systemctl enable --now ip-sentinel-master.service >/dev/null 2>&1 || \
               ! systemctl restart ip-sentinel-master.service >/dev/null 2>&1 || \
               ! systemctl is-active --quiet ip-sentinel-master.service || \
               ! systemctl restart ip-sentinel-tunnels.service >/dev/null 2>&1 || \
               ! systemctl is-active --quiet ip-sentinel-tunnels.service || \
               ! systemctl restart ip-sentinel-engine.service >/dev/null 2>&1 || \
               ! systemctl is-active --quiet ip-sentinel-engine.service; then
                : > "${SECURE_TMP}/MASTER_ROLLBACK_REQUIRED"
                echo -e "\033[31m❌ 回滚后 Master/引擎服务启动检查失败，已保留备份。\033[0m"
                return 1
            fi
        fi
    elif [ "${MASTER_SERVICE_STOPPED:-false}" = "true" ] && [ "${MASTER_ROLLBACK_CORE:-false}" = "true" ]; then
        nohup bash "${MASTER_DIR}/tg_master.sh" >/dev/null 2>&1 & disown 2>/dev/null
        [ -f "${MASTER_DIR}/engine/tunnel_manager.sh" ] && nohup bash "${MASTER_DIR}/engine/tunnel_manager.sh" >/dev/null 2>&1 & disown 2>/dev/null
        [ -f "${MASTER_DIR}/engine/scheduler.sh" ] && nohup bash "${MASTER_DIR}/engine/scheduler.sh" >/dev/null 2>&1 & disown 2>/dev/null
        if ! pgrep -f tg_master.sh >/dev/null 2>&1 || \
           ! pgrep -f tunnel_manager.sh >/dev/null 2>&1 || \
           ! pgrep -f "engine/scheduler.sh" >/dev/null 2>&1; then
            : > "${SECURE_TMP}/MASTER_ROLLBACK_REQUIRED"
            echo -e "\033[31m❌ 回滚后 Master/引擎进程启动检查失败，已保留备份。\033[0m"
            return 1
        fi
    fi

    return 0
}

do_master_summary() {
    echo "========================================================"
    if [ "$UPGRADE_MODE" == "true" ]; then
        echo "🎉 Master 控制中枢平滑热更新完成！"
        echo "🤖 新版中枢引擎已接管数据库，继续等待边缘节点汇报。"
        
        if [ "$SILENT_MASTER_OTA" == "true" ] && [ -n "$OTA_CHAT_ID" ] && [ -n "$TG_TOKEN" ]; then
            echo -e "\n📡 正在向指挥官发送司令部重构捷报..."
            curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                -d "chat_id=${OTA_CHAT_ID}" \
                -d "parse_mode=Markdown" \
                -d "text=✨ *司令部中枢热重载完成！*
🚀 当前内核已跃升至：\`v${TARGET_VERSION}\`
🤖 新版金蝉脱壳引擎已接管阵地，全舰队指控链路恢复正常。" > /dev/null
        fi
    else
        echo "🎉 Master 控制中枢部署完成！"
        echo "🤖 机器人现已开始全局接客，等待边缘节点注册。"
    fi
    echo "========================================================"

    if [ "$UPGRADE_MODE" == "false" ]; then
        echo -e "\n📡 正在向开源社区汇报装机量 (完全匿名，不收集IP)..."
        MASTER_COUNT=$(curl -s -m 3 "https://ip-sentinel-count.samanthaestime296.workers.dev/ping/master" || echo "")

        if [ -n "$MASTER_COUNT" ] && [[ "$MASTER_COUNT" =~ ^[0-9]+$ ]]; then
            echo -e "\033[32m✅ 感谢您成为全球第 ${MASTER_COUNT} 名 IP-Sentinel 中枢管理者！\033[0m"
        else
            echo -e "\033[32m✅ 感谢您部署 IP-Sentinel 控制中枢！\033[0m"
        fi
    fi

    echo -e "\n========================================================"
    echo -e "⭐ \033[33m开源不易，如果 IP-Sentinel 极大简化了您的多节点管理，请赐予我们一枚星标！\033[0m"
    echo -e "💡 \033[32m您的每一颗 Star 都是我们持续迭代架构、开发 Web 视窗化控制台的动力源泉。\033[0m"
    echo -e "👉 \033[36m\033[4m\033]8;;https://github.com/jasper-khan/IP-Sentinel\033\\点击此处直达 GitHub 仓库点亮 Star 🌟\033[0m\033]8;;\033\\"
    echo -e "========================================================\n"
}
