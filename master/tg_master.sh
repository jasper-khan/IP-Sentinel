#!/bin/bash

# ==========================================================
# 脚本名称: tg_master.sh
# 核心功能: 监听并处理全局指令回调，安全下发 OTA、Webhook、节点改名及僵尸节点清洗
# ==========================================================

CONF="/opt/ip_sentinel_master/master.conf"
[ ! -f "$CONF" ] && exit 1
source "$CONF"

REPO_RAW_URL="https://raw.githubusercontent.com/jasper-khan/IP-Sentinel/main"
MASTER_VERSION=${MASTER_VERSION:-"3.5.0"}

OFFSET_FILE="${MASTER_DIR}/.tg_offset"
[[ -f $OFFSET_FILE ]] || echo "0" > $OFFSET_FILE

# [V5 安全修复] 调试日志目录 (限权) 就地创建
mkdir -p "${MASTER_DIR}/logs" 2>/dev/null
chmod 700 "${MASTER_DIR}/logs" 2>/dev/null

# ==========================================================
# 1. 核心工具组件
# ==========================================================

# [全局旗帜渲染引擎] 基于 ISO 代码动态匹配地区国旗
get_flag() {
    local region=$(echo "$1" | tr 'a-z' 'A-Z')
    local base_cc="${region%%-*}"
    local flag="🌐"
    case "$base_cc" in
        US) flag="🇺🇸" ;; JP) flag="🇯🇵" ;; HK) flag="🇭🇰" ;; TW) flag="🇹🇼" ;; SG) flag="🇸🇬" ;;
        UK|GB) flag="🇬🇧" ;; DE) flag="🇩🇪" ;; FR) flag="🇫🇷" ;; NL) flag="🇳🇱" ;; CA) flag="🇨🇦" ;;
        AU) flag="🇦🇺" ;; KR) flag="🇰🇷" ;; IN) flag="🇮🇳" ;; BR) flag="🇧🇷" ;; RU) flag="🇷🇺" ;;
        CH) flag="🇨🇭" ;; SE) flag="🇸🇪" ;; NO) flag="🇳🇴" ;; DK) flag="🇩🇰" ;; FI) flag="🇫🇮" ;;
        IT) flag="🇮🇹" ;; ES) flag="🇪🇸" ;; PT) flag="🇵🇹" ;; IE) flag="🇮🇪" ;; PL) flag="🇵🇱" ;;
        AT) flag="🇦🇹" ;; BE) flag="🇧🇪" ;; TR) flag="🇹🇷" ;; ZA) flag="🇿🇦" ;; AE) flag="🇦🇪" ;;
        MY) flag="🇲🇾" ;; ID) flag="🇮🇩" ;; VN) flag="🇻🇳" ;; TH) flag="🇹🇭" ;; PH) flag="🇵🇭" ;;
        NZ) flag="🇳🇿" ;; AR) flag="🇦🇷" ;; CL) flag="🇨🇱" ;; MX) flag="🇲🇽" ;; IL) flag="🇮🇱" ;;
        SA) flag="🇸🇦" ;; EG) flag="🇪🇬" ;; NG) flag="🇳🇬" ;; KE) flag="🇰🇪" ;; RO) flag="🇷🇴" ;;
        BG) flag="🇧🇬" ;; CZ) flag="🇨🇿" ;; HU) flag="🇭🇺" ;; GR) flag="🇬🇷" ;; UA) flag="🇺🇦" ;;
        MO) flag="🇲🇴" ;; KH) flag="🇰🇭" ;; MM) flag="🇲🇲" ;; LA) flag="🇱🇦" ;;
        MN) flag="🇲🇳" ;; NP) flag="🇳🇵" ;; BD) flag="🇧🇩" ;;
    esac
    echo "$flag"
}

send_ui() {
    curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$1\",\"text\":\"$2\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$3}}" > /dev/null
}

send_msg() {
    local resp
    resp=$(curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" -d "text=$2" -d "parse_mode=Markdown")
    echo "[$(date '+%H:%M:%S')] send_msg chat=$1 resp=${resp:0:200}" >> "${MASTER_DIR}/logs/sendmsg_debug.log"
}

# [核心重构] UI 沉底重绘引擎：抹杀旧面板堆积，永远在最底部唤出新视图
render_ui() {
    local chat_id="$1"
    local msg_id="$2"
    local text="$3"
    local buttons="$4"

    if [ -n "$msg_id" ]; then
        # 1. 按钮触发：尝试物理删除旧面板，实现完美沉底转移
        local del_res=$(curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" \
            -d "chat_id=$chat_id" -d "message_id=$msg_id")
        
        # 2. 如果删除失败 (触发了 TG 48小时限制)，则剥夺旧面板的按键，使其变成安全的历史遗迹
        if [[ "$del_res" != *"\"ok\":true"* ]]; then
            curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageReplyMarkup" \
                -H "Content-Type: application/json" \
                -d "{\"chat_id\":\"$chat_id\",\"message_id\":\"$msg_id\",\"reply_markup\":{\"inline_keyboard\":[]}}" > /dev/null
        fi
    else
        # 3. [新增] 文本触发 (如输入/start)：尝试抹除全局记录的上一个遗留面板
        if [ -f "${MASTER_DIR}/.last_ui_id" ]; then
            local last_ui=$(cat "${MASTER_DIR}/.last_ui_id")
            curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" \
                -d "chat_id=$chat_id" -d "message_id=$last_ui" > /dev/null
        fi
    fi
    
    # 4. 无论如何，在最底部发送全新面板，并捕获最新 message_id 记录下来
    local res=$(curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -H "Content-Type: application/json" \
        -d "{\"chat_id\":\"$chat_id\",\"text\":\"$text\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"inline_keyboard\":$buttons}}")
    
    local new_id=$(echo "$res" | jq -r '.result.message_id // empty')
    if [ -n "$new_id" ] && [ "$new_id" != "null" ]; then
        echo "$new_id" > "${MASTER_DIR}/.last_ui_id"
    fi
}

# [核心重构] 文本沉底重绘引擎
render_msg() {
    local chat_id="$1"
    local msg_id="$2"
    local text="$3"

    if [ -n "$msg_id" ]; then
        local del_res=$(curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" -d "chat_id=$chat_id" -d "message_id=$msg_id")
        if [[ "$del_res" != *"\"ok\":true"* ]]; then
            curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageReplyMarkup" \
                -H "Content-Type: application/json" -d "{\"chat_id\":\"$chat_id\",\"message_id\":\"$msg_id\",\"reply_markup\":{\"inline_keyboard\":[]}}" > /dev/null
        fi
    fi
    send_msg "$chat_id" "$text"
}

# [SQLite 终极并发架构] 激活高并发 WAL 引擎防锁库，并设置安全锁时延
db_exec() {
    printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"
}

# ==========================================================
# [安全架构 V2] 每节点独立 PSK 的 HMAC 签名引擎 + TOFU 证书锁定
# - 签名密钥 = 节点注册时同步的 256-bit NODE_PSK (不再使用共享低熵 chat_id)
# - Master 调用前校验 Agent 自签证书指纹 (首次 TOFU 信任并入库，此后强校验)
# - 移除 V1 降级签名路径 (审计 V4：降级路径可被 MITM 主动诱发)
# ==========================================================
generate_signed_url() {
    local target_ip=$1
    local target_port=$2
    local action_path=$3
    local extra_query=$4
    local node_psk=$5
    local current_t=$(date +%s)

    local payload_v2="${action_path}"
    [ -n "$extra_query" ] && payload_v2="${payload_v2}?${extra_query}"
    payload_v2="${payload_v2}:${current_t}"

    local signature_v2=$(echo -n "$payload_v2" | openssl dgst -sha256 -mac HMAC -macopt key:"$node_psk" | awk '{print $NF}')

    local url_v2="https://${target_ip}:${target_port}${action_path}?t=${current_t}&sign=${signature_v2}"
    [ -n "$extra_query" ] && url_v2="${url_v2}&${extra_query}"

    echo "$url_v2"
}

# [TOFU 证书锁定] 返回: 0=校验通过/首次信任  1=指纹不匹配(疑似 MITM)  2=无法建立 TLS
verify_agent_tls() {
    local v_ip=$1
    local v_port=$2
    local v_node=$3

    local v_fp
    v_fp=$(echo | openssl s_client -connect "${v_ip}:${v_port}" -servername "agent" 2>/dev/null \
        | openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d'=' -f2 | tr -d ':')
    [ -z "$v_fp" ] && return 2

    local pinned
    pinned=$(db_exec "SELECT cert_fp FROM nodes WHERE chat_id='${CHAT_ID}' AND node_name='${v_node}' LIMIT 1;" | head -n 1 | tr -d '[:space:]')

    if [ -z "$pinned" ]; then
        db_exec "UPDATE nodes SET cert_fp='${v_fp}' WHERE chat_id='${CHAT_ID}' AND node_name='${v_node}';"
        return 0
    fi

    if [ "$pinned" = "$v_fp" ]; then
        return 0
    fi
    return 1
}

call_agent() {
    local node_key=$1
    local ips=$2
    local port=$3
    local path=$4
    local extra_q=$5
    local res="FAILED"

    # [V2 门禁] 无独立 PSK 的节点 (老版本/异常注册) 一律拒绝下发指令
    local node_psk
    node_psk=$(db_exec "SELECT psk FROM nodes WHERE chat_id='${CHAT_ID}' AND node_name='${node_key}' LIMIT 1;" | head -n 1 | tr -d '[:space:]')
    if ! [[ "$node_psk" =~ ^[0-9a-fA-F]{64}$ ]]; then
        echo "FAILED_NO_PSK"
        return
    fi

    local clean_ips=$(echo "$ips" | tr '_' ',')
    IFS=',' read -r -a ip_array <<< "$clean_ips"
    for ip in "${ip_array[@]}"; do
        if [ -n "$ip" ]; then
            # [TOFU] 证书指纹校验：不匹配即中止该节点通讯 (防 MITM)
            verify_agent_tls "$ip" "$port" "$node_key"
            TLS_RC=$?
            if [ "$TLS_RC" -eq 1 ]; then
                send_msg "$CHAT_ID" "🚨 **[安全告警] 节点 \`${node_key}\` (${ip}) 证书指纹与锁定值不符！疑似中间人攻击，本次指令已中止。**"
                echo "FAILED_TLS_MISMATCH"
                return
            fi

            local url_v2=$(generate_signed_url "$ip" "$port" "$path" "$extra_q" "$node_psk")
            res=$(curl -k -s --connect-timeout 4 -m 12 "$url_v2" || echo "FAILED")

            if [ "$res" != "FAILED" ] && [ -n "$res" ]; then
                echo "$res"
                return
            fi
        fi
    done
    echo "FAILED"
}

# ==========================================================
# 2. 数据库热升级自愈系统
# ==========================================================
db_exec "PRAGMA journal_mode=WAL;" > /dev/null 2>&1
db_exec "PRAGMA synchronous=NORMAL;" > /dev/null 2>&1

db_exec "ALTER TABLE nodes ADD COLUMN region TEXT DEFAULT 'UNKNOWN';" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN node_alias TEXT;" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN enable_ota TEXT DEFAULT 'false';" 2>/dev/null
# [V2 安全修复] 每节点独立 PSK 与 TOFU 证书指纹列；[引擎配套] SSH 隧道出口列；[persona] 区域参数列
db_exec "ALTER TABLE nodes ADD COLUMN psk TEXT;" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN cert_fp TEXT;" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN ssh_port TEXT DEFAULT '22';" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN tunnel_user TEXT DEFAULT 'sentinel-tunnel';" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN lang_params TEXT;" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN base_lat TEXT;" 2>/dev/null
db_exec "ALTER TABLE nodes ADD COLUMN base_lon TEXT;" 2>/dev/null
# [引擎调度开关] 节点级暂停/恢复浏览器养护 (TG 面板可切)
db_exec "ALTER TABLE nodes ADD COLUMN engine_enabled TEXT DEFAULT 'true';" 2>/dev/null

db_exec "CREATE TABLE IF NOT EXISTS ip_trend_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    node_name TEXT,
    check_time DATETIME DEFAULT CURRENT_TIMESTAMP,
    scam_score INTEGER,
    nf_status TEXT
);" 2>/dev/null
db_exec "ALTER TABLE ip_trend_log ADD COLUMN goog_status TEXT DEFAULT 'Unknown';" 2>/dev/null
db_exec "ALTER TABLE ip_trend_log ADD COLUMN gpt_status TEXT DEFAULT 'Unknown';" 2>/dev/null

# ==========================================================
# 3. 核心长轮询调度器
# ==========================================================
while true; do
    OFFSET=$(cat $OFFSET_FILE)
    UPDATES=$(curl -s --connect-timeout 5 -m 35 "https://api.telegram.org/bot${TG_TOKEN}/getUpdates?offset=${OFFSET}&timeout=30")
    
    COUNT=$(echo "$UPDATES" | jq -r '.result | length' 2>/dev/null)
    
    if [[ "$COUNT" =~ ^[0-9]+$ ]] && [ "$COUNT" -gt 0 ]; then
        echo "$UPDATES" | jq -c '.result[]' | while read -r UPDATE; do
            UPDATE_ID=$(echo "$UPDATE" | jq -r '.update_id')
            echo $((UPDATE_ID + 1)) > $OFFSET_FILE
            
            CHAT_ID=$(echo "$UPDATE" | jq -r '.message.chat.id // .callback_query.message.chat.id')
            
            # [安全漏洞 #106 修复] 严格区分消息文本与按钮回调源
            MSG_TEXT=$(echo "$UPDATE" | jq -r '.message.text // empty')
            
            # 👇 --- 新增这一行：提取用户的文本气泡 ID --- 👇
            USER_MSG_ID=$(echo "$UPDATE" | jq -r '.message.message_id // empty')
            
            CB_DATA=$(echo "$UPDATE" | jq -r '.callback_query.data // empty')
            CB_ID=$(echo "$UPDATE" | jq -r '.callback_query.id // empty')
            MSG_ID=$(echo "$UPDATE" | jq -r '.callback_query.message.message_id // empty')
            
            # 优先级：按钮回调 > 纯文本
            if [ -n "$CB_DATA" ]; then
                TEXT="$CB_DATA"
            else
                TEXT="$MSG_TEXT"
            fi

            # ----------------------------------------------------------
            # [业务流 A] 深海声呐态势感知一键入库模块
            # ----------------------------------------------------------
            if [[ "$TEXT" == "svq|"* ]]; then
                IFS='|' read -r MAGIC RAW_NODE_ID RAW_SCORE RAW_GOOG_ST RAW_NF_ST RAW_GPT_ST <<< "$TEXT"
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                
                NODE_ID=$(echo "$RAW_NODE_ID" | tr -cd 'a-zA-Z0-9_.-')
                SCORE=$(echo "$RAW_SCORE" | tr -cd '0-9')
                GOOG_ST=$(echo "$RAW_GOOG_ST" | tr -d '"'\''\`\$\|&;<>\n\r')
                NF_ST=$(echo "$RAW_NF_ST" | tr -d '"'\''\`\$\|&;<>\n\r')
                GPT_ST=$(echo "$RAW_GPT_ST" | tr -d '"'\''\`\$\|&;<>\n\r')

                if [ -n "$NODE_ID" ] && [ -n "$SCORE" ]; then
                    db_exec "INSERT INTO ip_trend_log (node_name, scam_score, goog_status, nf_status, gpt_status) VALUES ('$NODE_ID', '$SCORE', '$GOOG_ST', '$NF_ST', '$GPT_ST');"
                    
                    if [ -n "$CB_ID" ]; then
                        curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" \
                            -d "callback_query_id=${CB_ID}" \
                            -d "text=✅ 报告已成功录入趋势库！" \
                            -d "show_alert=false" > /dev/null
                    fi

                    if [ -n "$MSG_ID" ]; then
                        curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/editMessageReplyMarkup" \
                            -H "Content-Type: application/json" \
                            -d "{\"chat_id\":\"${CHAT_ID}\",\"message_id\":\"${MSG_ID}\",\"reply_markup\":{\"inline_keyboard\":[[{\"text\":\"✅ 此报告已存档\",\"callback_data\":\"ignore\"}],[{\"text\":\"⚙️ 调出该节点控制台\",\"callback_data\":\"manage:${NODE_ID}\"}]]}}" > /dev/null
                    fi
                else
                    if [ -n "$CB_ID" ]; then
                        curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" \
                            -d "callback_query_id=${CB_ID}" \
                            -d "text=❌ 数据解析失败，入库中止。" \
                            -d "show_alert=true" > /dev/null
                    fi
                fi
                continue
            fi
            
            REPLY_TO_TEXT=$(echo "$UPDATE" | jq -r '.message.reply_to_message.text // empty')
            echo "[$(date '+%H:%M:%S')] DBG text_len=${#TEXT} reply_len=${#REPLY_TO_TEXT} head=[$(printf '%s' "$TEXT" | head -c 60)]" >> "${MASTER_DIR}/logs/reconfig_debug.log"

            # ----------------------------------------------------------
            # [业务流 B] 拦截并解析别名重命名回执
            # ----------------------------------------------------------
            if [[ "$REPLY_TO_TEXT" == *"✏️ 请回复本消息以重命名节点:"* ]]; then
                 TARGET_NODE=$(echo "$REPLY_TO_TEXT" | grep -v "✏️" | grep -v "仅限" | tr -d '\` ' | tr -cd 'a-zA-Z0-9_.-' | head -n 1)
                 NEW_ALIAS=$(echo "$TEXT" | sed 's/_/-/g' | tr -d '"'\''\`\$\|&;<>\n\r:' | cut -c 1-30)
                
                 if [ -n "$TARGET_NODE" ] && [ -n "$NEW_ALIAS" ]; then
                     TEXT="do_rename:${TARGET_NODE}:${NEW_ALIAS}"
                 fi
                 fi

             # ----------------------------------------------------------
             # [业务流 B2] 拦截并解析 Bot 凭证切换回执 (Issue #102)
             # [双触发] ① 引用回复提示消息 ② 文本形态直接命中 "Token + ChatID"
             #          (客户端未挂引用时兜底，防止凭证消息被静默吞掉)
             # ----------------------------------------------------------
             RECONFIG_CANDIDATE=""
             if [[ "$REPLY_TO_TEXT" == *"🔁 请回复本消息填写新 Bot 凭证:"* ]]; then
                 RECONFIG_CANDIDATE="$TEXT"
             elif [[ "$TEXT" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}[[:space:]]+-?[0-9]{5,}[[:space:]]*$ ]] || \
                  [[ "$TEXT" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}[[:space:]]*$ ]]; then
                 RECONFIG_CANDIDATE="$TEXT"
             fi
             if [ -n "$RECONFIG_CANDIDATE" ]; then
                 # [格式归一] 支持上下两行 (Token/ChatID) 或一行空格分隔
                 RECONFIG_INPUT=$(echo "$RECONFIG_CANDIDATE" | tr $'\n' ' ' | tr -cd '0-9A-Za-z:_ -' | tr -s ' ' | sed 's/^ //; s/ $//')
                 echo "[$(date '+%H:%M:%S')] B2_HIT INPUT=[$RECONFIG_INPUT]" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                 if [ -n "$RECONFIG_INPUT" ]; then
                     TEXT="do_reconfig:${RECONFIG_INPUT}"
                 fi
             fi

            if [ -n "$CB_ID" ]; then
                curl -s --connect-timeout 5 -m 10 -X POST "https://api.telegram.org/bot${TG_TOKEN}/answerCallbackQuery" -d "callback_query_id=${CB_ID}" > /dev/null
            fi

            # ----------------------------------------------------------
            # [业务流 C] 节点注册与通讯架构解包通道
            # ----------------------------------------------------------
            if [[ "$TEXT" == *"#REGISTER#"* ]]; then
                REG_LINE=$(echo "$TEXT" | grep "#REGISTER#" | head -n 1 | tr -d '\` ')

                # [运维取证] 注册报文原文留档 (排查拆行/截断类问题)
                {
                    echo "[$(date '+%Y-%m-%d %H:%M:%S')] NF=$(echo "$REG_LINE" | awk -F'|' '{print NF}')"
                    echo "RAW_TEXT=[${TEXT:0:400}]"
                    echo "---"
                } >> "${MASTER_DIR}/logs/register_debug.log" 2>/dev/null

                # [V2 加固] 注册报文含 PSK (敏感凭证)——解析完成后立即删除 TG 消息,
                # 避免密钥长期留存于聊天历史 (任何能读该聊天的人 = 能伪造指令)
                if [ -n "$USER_MSG_ID" ]; then
                    curl -s -m 5 -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" \
                        -d "chat_id=${CHAT_ID}" -d "message_id=${USER_MSG_ID}" >/dev/null 2>&1 || true
                fi
                
                FIELD_COUNT=$(echo "$REG_LINE" | awk -F'|' '{print NF}')
                # 字段 11-13: LANG_PARAMS/BASE_LAT/BASE_LON (引擎 persona 数据)
                RAW_LANG_PARAMS=""
                RAW_BASE_LAT=""
                RAW_BASE_LON=""
                if [ "$FIELD_COUNT" -ge 13 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_PSK RAW_SSH_PORT RAW_TUNNEL_USER RAW_LANG_PARAMS RAW_BASE_LAT RAW_BASE_LON <<< "$REG_LINE"
                elif [ "$FIELD_COUNT" -eq 12 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_PSK RAW_SSH_PORT RAW_TUNNEL_USER RAW_LANG_PARAMS RAW_BASE_LAT <<< "$REG_LINE"
                elif [ "$FIELD_COUNT" -eq 11 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_PSK RAW_SSH_PORT RAW_TUNNEL_USER RAW_LANG_PARAMS <<< "$REG_LINE"
                elif [ "$FIELD_COUNT" -eq 10 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_PSK RAW_SSH_PORT RAW_TUNNEL_USER <<< "$REG_LINE"
                elif [ "$FIELD_COUNT" -eq 9 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_PSK RAW_SSH_PORT <<< "$REG_LINE"
                    RAW_TUNNEL_USER="sentinel-tunnel"
                elif [ "$FIELD_COUNT" -eq 8 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA RAW_PSK <<< "$REG_LINE"
                    RAW_SSH_PORT="22"
                    RAW_TUNNEL_USER="sentinel-tunnel"
                elif [ "$FIELD_COUNT" -eq 7 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS RAW_OTA <<< "$REG_LINE"
                    RAW_PSK=""
                    RAW_SSH_PORT="22"
                    RAW_TUNNEL_USER="sentinel-tunnel"
                elif [ "$FIELD_COUNT" -eq 6 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT RAW_ALIAS <<< "$REG_LINE"
                    RAW_OTA="false"
                    RAW_PSK=""
                    RAW_SSH_PORT="22"
                    RAW_TUNNEL_USER="sentinel-tunnel"
                elif [ "$FIELD_COUNT" -eq 5 ]; then
                    IFS='|' read -r MAGIC RAW_REGION RAW_NODE RAW_IP RAW_PORT <<< "$REG_LINE"
                    RAW_ALIAS="$RAW_NODE"
                    RAW_OTA="false"
                    RAW_PSK=""
                    RAW_SSH_PORT="22"
                    RAW_TUNNEL_USER="sentinel-tunnel"
                else
                    IFS='|' read -r MAGIC RAW_NODE RAW_IP RAW_PORT <<< "$REG_LINE"
                    RAW_REGION="UNKNOWN"
                    RAW_ALIAS="$RAW_NODE"
                    RAW_OTA="false"
                    RAW_PSK=""
                    RAW_SSH_PORT="22"
                    RAW_TUNNEL_USER="sentinel-tunnel"
                fi
                
                CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                AGENT_REGION=$(echo "$RAW_REGION" | tr -cd 'a-zA-Z0-9' | cut -c 1-10)
                NODE_NAME=$(echo "$RAW_NODE" | tr -cd 'a-zA-Z0-9_.-' | cut -c 1-30)
                AGENT_IP=$(echo "$RAW_IP" | tr -cd 'a-zA-Z0-9.:\[\]-_,' | cut -c 1-150)
                AGENT_PORT=$(echo "$RAW_PORT" | tr -cd '0-9' | cut -c 1-5)
                NODE_ALIAS=$(echo "$RAW_ALIAS" | tr -d '"'\''\`\$\|&;<>\n\r' | cut -c 1-30)
                [ -z "$NODE_ALIAS" ] && NODE_ALIAS="$NODE_NAME"
                AGENT_OTA=$(echo "$RAW_OTA" | tr -cd 'a-z')
                [ -z "$AGENT_OTA" ] && AGENT_OTA="false"
                
                # [安全漏洞 #107 修复] 拒绝私有、链路本地及保留 IP 防御 SSRF 内网探测
                if [[ "$AGENT_IP" =~ ^127\.|^10\.|^192\.168\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.|^169\.254\.|^100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.|^::1$|^[fF][cdCD][0-9a-fA-F]{2}:|^[fF][eE][89abAB][0-9a-fA-F]: ]]; then
                    send_msg "$CHAT_ID" "⛔ **安全拦截**：禁止注册私网/保留/回环 IP，防止 SSRF 攻击渗透。"
                    continue
                fi
                
                if [ -z "$NODE_NAME" ] || [ -z "$AGENT_IP" ] || [ -z "$AGENT_PORT" ] || [ -z "$CHAT_ID" ]; then
                    send_msg "$CHAT_ID" "⛔ **安全拦截**：检测到非法注册载荷，请求已拒绝。"
                    continue
                fi

                # [V2 安全修复] 校验并入库每节点独立 PSK；无 PSK 或格式非法的节点只登记档案、拒绝指令下发
                AGENT_PSK=$(echo "$RAW_PSK" | tr -cd '0-9a-fA-F' | cut -c 1-64)
                if [ ${#AGENT_PSK} -ne 64 ]; then
                    AGENT_PSK=""
                fi

                # [引擎配套] SSH 隧道出口信息 (端口+用户) 清洗入库
                AGENT_SSH_PORT=$(echo "$RAW_SSH_PORT" | tr -cd '0-9' | cut -c 1-5)
                [ -z "$AGENT_SSH_PORT" ] && AGENT_SSH_PORT="22"
                AGENT_TUNNEL_USER=$(echo "$RAW_TUNNEL_USER" | tr -cd 'a-zA-Z0-9_-')
                [ -z "$AGENT_TUNNEL_USER" ] && AGENT_TUNNEL_USER="sentinel-tunnel"

                # [引擎 persona] 区域参数清洗 (hl=xx&gl=XX / 十进制坐标)
                AGENT_LANG_PARAMS=$(echo "$RAW_LANG_PARAMS" | tr -cd 'a-zA-Z0-9=&_-' | cut -c 1-40)
                AGENT_BASE_LAT=$(echo "$RAW_BASE_LAT" | tr -cd '0-9.-' | cut -c 1-12)
                AGENT_BASE_LON=$(echo "$RAW_BASE_LON" | tr -cd '0-9.-' | cut -c 1-13)

                if [ -n "$AGENT_PSK" ]; then
                    db_exec "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen, region, node_alias, enable_ota, psk, ssh_port, tunnel_user, lang_params, base_lat, base_lon) VALUES ('$CHAT_ID', '$NODE_NAME', '$AGENT_IP', '$AGENT_PORT', CURRENT_TIMESTAMP, '$AGENT_REGION', '$NODE_ALIAS', '$AGENT_OTA', '$AGENT_PSK', '$AGENT_SSH_PORT', '$AGENT_TUNNEL_USER', '$AGENT_LANG_PARAMS', '$AGENT_BASE_LAT', '$AGENT_BASE_LON') ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$AGENT_IP', agent_port='$AGENT_PORT', last_seen=CURRENT_TIMESTAMP, region='$AGENT_REGION', node_alias='$NODE_ALIAS', enable_ota='$AGENT_OTA', psk='$AGENT_PSK', ssh_port='$AGENT_SSH_PORT', tunnel_user='$AGENT_TUNNEL_USER', lang_params=COALESCE(NULLIF(excluded.lang_params,''), lang_params), base_lat=COALESCE(NULLIF(excluded.base_lat,''), base_lat), base_lon=COALESCE(NULLIF(excluded.base_lon,''), base_lon);"
                else
                    db_exec "INSERT INTO nodes (chat_id, node_name, agent_ip, agent_port, last_seen, region, node_alias, enable_ota) VALUES ('$CHAT_ID', '$NODE_NAME', '$AGENT_IP', '$AGENT_PORT', CURRENT_TIMESTAMP, '$AGENT_REGION', '$NODE_ALIAS', '$AGENT_OTA') ON CONFLICT(chat_id, node_name) DO UPDATE SET agent_ip='$AGENT_IP', agent_port='$AGENT_PORT', last_seen=CURRENT_TIMESTAMP, region='$AGENT_REGION', node_alias='$NODE_ALIAS', enable_ota='$AGENT_OTA';"
                    send_msg "$CHAT_ID" "⚠️ **安全提示**：节点 \`$NODE_ALIAS\` 注册载荷不含独立 PSK (老版本 Agent)。\n仅登记档案，指令下发已被拒绝；请尽快升级该节点以启用每节点密钥。"
                fi
                
                FMT_AGENT_IP=$(echo "$AGENT_IP" | tr '_' ',')
                MAIN_SHOW_IP=$(echo "$FMT_AGENT_IP" | cut -d',' -f1)
                BACKUP_SHOW_IP=$(echo "$FMT_AGENT_IP" | cut -d',' -f2-)
                if [ -n "$BACKUP_SHOW_IP" ]; then
                    SHOW_MSG="✅ **司令部确认 (v${MASTER_VERSION})**%0A节点 \`${NODE_ALIAS}\` 档案已录入！%0A🌐 主通讯：\`${MAIN_SHOW_IP}\`%0A📡 容灾备用：\`${BACKUP_SHOW_IP}\`"
                else
                    SHOW_MSG="✅ **司令部确认 (v${MASTER_VERSION})**%0A节点 \`${NODE_ALIAS}\` 档案已录入！%0A🌐 通讯 IP：\`${MAIN_SHOW_IP}\`"
                fi
                send_msg "$CHAT_ID" "$SHOW_MSG"
                
                REGION_DATA=$(db_exec "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                if [ -n "$REGION_DATA" ]; then
                    BTNS="["
                    while IFS='|' read -r REGION_NAME NODE_COUNT; do
                        [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                        FLAG=$(get_flag "$REGION_NAME")
                        BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台已登记)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                    done <<< "$REGION_DATA"
                    BTNS="${BTNS%,}]"
                    render_ui "$CHAT_ID" "" "🌍 **全视界战略雷达**\n请选择要检阅的战区：" "$BTNS"
                fi
                continue
            fi

            # ----------------------------------------------------------
            # [业务流 D] 控制中枢指令集与沉底呈现引擎
            # ----------------------------------------------------------
            case "$TEXT" in
                "/start"|"/menu")
                    # 👇 --- 新增这段逻辑：抹杀用户发送的 /start 文本指令 --- 👇
                    if [ -n "$USER_MSG_ID" ] && [ -z "$CB_ID" ]; then
                        curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/deleteMessage" \
                            -d "chat_id=$CHAT_ID" -d "message_id=$USER_MSG_ID" > /dev/null
                    fi
                    # 👆 ----------------------------------------------------- 👆
                    
                    REMOTE_VER=$(curl -s -m 2 "${REPO_RAW_URL}/version.txt" | grep "^MASTER_VERSION=" | cut -d'=' -f2 | tr -d '[:space:]')
                    VER_INFO="当前版本: \`v${MASTER_VERSION}\`"
                    
                    BTN_MASTER_OTA=""
                    if [ -n "$REMOTE_VER" ]; then
                        if [ "$REMOTE_VER" != "$MASTER_VERSION" ]; then
                            VER_INFO="${VER_INFO}\n✨ **发现新版本**: \`v${REMOTE_VER}\` (可执行中枢热重载)"
                            if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "${ENABLE_MASTER_OTA:-false}" == "true" ]; then
                                BTN_MASTER_OTA="[{\"text\":\"🆙 升级控制中枢至 v${REMOTE_VER}\",\"callback_data\":\"master_ota_confirm\"}],"
                            fi
                        else
                            VER_INFO="当前版本: \`v${MASTER_VERSION}\` (✅已是最新)"
                        fi
                    fi

                    NODE_COUNT=$(db_exec "SELECT COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID';")

                    if [ "$IS_OFFICIAL_GATEWAY" != "true" ]; then
                        BTNS="[${BTN_MASTER_OTA}[{\"text\":\"🌍 进入全球雷达 (管理节点)\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 唤醒全局巡逻\",\"callback_data\":\"all_run\"}, {\"text\":\"📊 获取全局简报\",\"callback_data\":\"all_reports\"}], [{\"text\":\"🔄 全网节点 OTA 热重载\",\"callback_data\":\"all_ota_confirm\"}, {\"text\":\"🔁 全舰队切换 Bot 凭证\",\"callback_data\":\"reconfig_confirm\"}], [{\"text\":\"🌟 前往 GitHub 点亮星标\",\"url\":\"https://github.com/jasper-khan/IP-Sentinel\"}]]"
                    else
                        BTNS="[[{\"text\":\"🌍 进入全球雷达 (管理节点)\",\"callback_data\":\"list_nodes\"}], [{\"text\":\"🚀 唤醒全局巡逻\",\"callback_data\":\"all_run\"}, {\"text\":\"📊 获取全局简报\",\"callback_data\":\"all_reports\"}], [{\"text\":\"🌟 前往 GitHub 点亮星标\",\"url\":\"https://github.com/jasper-khan/IP-Sentinel\"}]]"
                    fi
                    DISP_MASTER="${MASTER_NODE_NAME:-未命名中枢}"
                    
                    # [文案修正] 明确“已登记”概念，避免误导为“实时心跳在线”
                    TEXT_MSG="🛡️ **IP-Sentinel 控制中枢**\n${VER_INFO}\n中枢节点: \`${DISP_MASTER}\`\n\n📋 档案库: 已登记 \`${NODE_COUNT}\` 台节点\n欢迎回来，管理者。请下达系统指令："
                    render_ui "$CHAT_ID" "$MSG_ID" "$TEXT_MSG" "$BTNS"
                    ;;
                    
                "all_ota_confirm")
                    if [ -z "$CB_ID" ]; then send_msg "$CHAT_ID" "⛔ 安全拦截：非法特权执行环境。"; continue; fi
                    CONFIRM_BTNS="[[{\"text\":\"🚨 我已了解风险，下发核按钮指令！\",\"callback_data\":\"all_ota_execute\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【最高指令：全舰队 OTA 升级】**\n\n此操作将向您名下**所有开启 OTA 权限的节点**下发重组指令，强制从云端拉取最新代码并进行热重载。\n\n⚠️ **核按钮风险提示**：\n1. 升级过程中守护进程会短暂重启，节点可能出现临时离线。\n2. 若遇 GitHub 源屏蔽或网络极度恶劣，少数节点可能需要手动干预。\n\n**是否确定挂载并执行 OTA 指令？**"
                    render_ui "$CHAT_ID" "$MSG_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    ;;

                "reconfig_confirm")
                    if [ -z "$CB_ID" ]; then send_msg "$CHAT_ID" "⛔ 安全拦截：非法特权执行环境。"; continue; fi
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认切换，填写新凭证\",\"callback_data\":\"reconfig_input\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【最高指令：全舰队切换 Bot 凭证】**\n\n此操作将向您名下**所有开启 OTA 权限的节点**下发凭证切换指令，各节点会:\n1. 用新 Token 验证身份并向新 Bot 发送注册回执。\n2. 原子重写本地凭证 (Token / Chat ID / API 地址)。\n3. 若 Chat ID 变更，自动重启守护进程完成密钥轮换。\n\n⚠️ **风险提示**：\n1. 切换完成后请**立即停止旧 Bot 的司令部进程**，防止双司令部抢注。\n2. 未开启 OTA 权限的节点不会收到指令，需手动 SSH 处理。\n3. 趋势历史 (ip_trend_log) 保留在旧库，新司令部从零开始。\n\n**是否确定执行切换？**"
                    render_ui "$CHAT_ID" "$MSG_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    ;;

                "reconfig_input")
                    if [ -z "$CB_ID" ]; then send_msg "$CHAT_ID" "⛔ 安全拦截：非法特权执行环境。"; continue; fi
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    # [Issue #102 修复] 原 \\` 在双引号内触发反引号命令替换，格式文本被吞；改用纯文本两行式提示
                    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                         -H "Content-Type: application/json" \
                         -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"🔁 请回复本消息填写新 Bot 凭证:\\n第一行: 新 Token (形如 123456789:AAH...)\\n第二行: 新 Chat ID (形如 -1001234567890)\\n*(也支持一行空格分隔)*\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"force_reply\":true}}" > /dev/null
                    ;;

                do_reconfig:*)
                    echo "[$(date '+%H:%M:%S')] RC_STEP0 ENTER CHAT_ID=$CHAT_ID INPUT_LEN=${#TEXT}" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                    RECONFIG_INPUT=$(echo "${TEXT#*:}" | tr -s ' ' | sed 's/^ //; s/ $//')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    NEW_TOKEN=$(echo "$RECONFIG_INPUT" | awk '{print $1}')
                    NEW_CHAT_ID=$(echo "$RECONFIG_INPUT" | awk '{print $2}')
                    echo "[$(date '+%H:%M:%S')] RC_STEP1 PARSED TOKEN_LEN=${#NEW_TOKEN} CHATID=[$NEW_CHAT_ID]" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                    
                    # [格式清洗] 强校验凭证形态
                    if ! [[ "$NEW_TOKEN" =~ ^[0-9]{6,}:[A-Za-z0-9_-]{30,}$ ]] || ! [[ "$NEW_CHAT_ID" =~ ^-?[0-9]{5,}$ ]]; then
                        echo "[$(date '+%H:%M:%S')] RC_STEP2 FORMAT_FAIL" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                        render_msg "$CHAT_ID" "$MSG_ID" "⛔ **凭证格式校验失败**%0AToken 形如 \`123456789:AAH...\`，Chat ID 为纯数字。请重新回复。"
                        continue
                    fi
                    
                    # [步骤 0] Master 端先 getMe 验证新 Token，手误凭证在此拦截，不浪费全舰队流量
                    render_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在验证新 Bot Token 有效性..."
                    echo "[$(date '+%H:%M:%S')] RC_STEP3 GETME_START" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                    ME_RESULT=$(curl -s --connect-timeout 5 -m 10 "https://api.telegram.org/bot${NEW_TOKEN}/getMe")
                    echo "[$(date '+%H:%M:%S')] RC_STEP4 GETME_DONE resp=${ME_RESULT:0:120}" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                    if ! echo "$ME_RESULT" | grep -q '"ok":true'; then
                        render_msg "$CHAT_ID" "$MSG_ID" "❌ **新 Token 验证失败**%0A$(echo "$ME_RESULT" | jq -r '.description // .error_code' 2>/dev/null)%0A凭证未下发，请重新填写。"
                        continue
                    fi
                    NEW_BOT_NAME=$(echo "$ME_RESULT" | jq -r '.result.username // "未知"' 2>/dev/null)
                    
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND enable_ota='true';")
                    echo "[$(date '+%H:%M:%S')] RC_STEP5 NODES_FOUND=$(echo "$NODE_DATA" | grep -c '|')" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                    if [ -z "$NODE_DATA" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 您名下暂无开启 OTA 权限的记录节点，无需切换。"
                        continue
                    fi
                    
                    # [载荷封装] 安全 Base64 (URL 友好)
                    RECONFIG_JSON=$(printf '{"token":"%s","chat_id":"%s"}' "$NEW_TOKEN" "$NEW_CHAT_ID")
                    RECONFIG_B64=$(echo -n "$RECONFIG_JSON" | base64 | tr -d '\n' | tr '+/' '-_')
                    
                    render_msg "$CHAT_ID" "$MSG_ID" "📢 **司令部指令下达：正在向全舰队切换 Bot 凭证...**%0A目标 Bot: \`@$NEW_BOT_NAME\`%0A*(各节点成功后会主动向新 Bot 发送注册回执，请注意查收)*"
                    
                    SUCCESS_COUNT=0
                    FAIL_LIST=""
                    TOTAL_COUNT=$(echo "$NODE_DATA" | grep -c '|')
                    
                    while IFS='|' read -r NNAME AIP APORT; do
                        [ -z "$NNAME" ] && continue
                        echo "[$(date '+%H:%M:%S')] RC_STEP6 CALL $NNAME ($AIP:$APORT)" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                        RESPONSE=$(call_agent "$NNAME" "$AIP" "$APORT" "/trigger_reconfig" "b64=${RECONFIG_B64}")
                        echo "[$(date '+%H:%M:%S')] RC_STEP7 RESP $NNAME => ${RESPONSE:0:80}" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                        if [[ "$RESPONSE" == *"Action Accepted"* ]]; then
                            SUCCESS_COUNT=$((SUCCESS_COUNT+1))
                        else
                            FAIL_LIST="${FAIL_LIST}\`$NNAME\` (${AIP}) → ${RESPONSE}%0A"
                        fi
                        sleep 1.2
                    done <<< "$NODE_DATA"
                    
                    echo "[$(date '+%H:%M:%S')] RC_STEP8 SUMMARY success=$SUCCESS_COUNT/$TOTAL_COUNT" >> "${MASTER_DIR}/logs/reconfig_debug.log"
                    
                    if [ -z "$FAIL_LIST" ]; then
                        SUMMARY="✅ **全舰队切换完成**%0A成功: ${SUCCESS_COUNT}/${TOTAL_COUNT} 台%0A%0A📋 **后续操作清单**:%0A1. 前往新 Bot 查看注册回执 (各节点已自动发送)。%0A2. 在新机器上部署新司令部 (或直接迁移本库)。%0A3. 确认新司令部接管后，**停止旧司令部的 tg_master 进程**。"
                    else
                        SUMMARY="⚠️ **切换完成 (部分失败)**%0A成功: ${SUCCESS_COUNT}/${TOTAL_COUNT} 台%0A%0A❌ **失败清单 (需手动 SSH 处理)**:%0A${FAIL_LIST}%0A📋 失败节点请手动更新 /opt/ip_sentinel/config.conf 并重启 daemon。"
                    fi
                    send_msg "$CHAT_ID" "$SUMMARY"
                    ;;

                "all_ota_execute")
                    if [ -z "$CB_ID" ]; then send_msg "$CHAT_ID" "⛔ 安全拦截：非法特权执行环境。"; continue; fi
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND enable_ota='true';")
                    if [ -z "$NODE_DATA" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 您名下暂无开启 OTA 权限的记录节点。"
                    else
                        render_msg "$CHAT_ID" "$MSG_ID" "📢 **司令部指令下达：正在唤醒全舰队执行 OTA 升级...**%0A*(节点升级成功后会主动发回新的入库确认，请注意查收)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            call_agent "$NNAME" "$AIP" "$APORT" "/trigger_ota" "" > /dev/null &
                            sleep 0.3
                        done
                    fi
                    ;;

                "master_ota_confirm")
                    if [ -z "$CB_ID" ]; then send_msg "$CHAT_ID" "⛔ 安全拦截：非法特权执行环境。"; continue; fi
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认重构司令部\",\"callback_data\":\"master_ota_execute\"}], [{\"text\":\"取消操作\",\"callback_data\":\"/start\"}]]"
                    WARNING_MSG="☢️ **【最高指令：中枢金蝉脱壳】**\n\n此操作将拉取最新源码并强行覆盖司令部核心进程。\n\n⚠️ **风险提示**：\n升级期间司令部将短暂失联（约3-5秒）。完成后会自动发送捷报。\n\n**是否确定执行司令部自我升级？**"
                    render_ui "$CHAT_ID" "$MSG_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    ;;

                "master_ota_execute")
                    if [ -z "$CB_ID" ] || [ "${ENABLE_MASTER_OTA:-false}" != "true" ]; then
                        send_msg "$CHAT_ID" "⛔ 安全拦截：非法特权执行环境或权限未开。"
                        continue
                    fi
                    render_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在下载重构图纸，司令部即将进入静默重启..."

                    # [V5 安全修复] mktemp 私有路径替代可预测的 /tmp/install_master.sh
                    MASTER_OTA_SCRIPT=$(mktemp "${MASTER_DIR}/ota_install.XXXXXX.sh")
                    curl -fsSL "${REPO_RAW_URL}/master/install_master.sh" -o "$MASTER_OTA_SCRIPT"

                    if ! bash -n "$MASTER_OTA_SCRIPT" >/dev/null 2>&1; then
                        send_msg "$CHAT_ID" "❌ OTA 传输受损：脚本下载不完整，已触发防砖熔断，升级取消！"
                        rm -f "$MASTER_OTA_SCRIPT"
                        continue
                    fi

                    chmod 700 "$MASTER_OTA_SCRIPT"

                    if command -v systemd-run >/dev/null 2>&1; then
                        systemd-run --quiet --no-block /bin/bash -c "export SILENT_MASTER_OTA='true'; export OTA_CHAT_ID='$CHAT_ID'; bash '$MASTER_OTA_SCRIPT'"
                    else
                        export SILENT_MASTER_OTA="true"
                        export OTA_CHAT_ID="$CHAT_ID"
                        nohup bash "$MASTER_OTA_SCRIPT" >/dev/null 2>&1 & disown
                    fi
                    sleep 10
                    ;;

                "all_reports")
                    NODE_DATA=$(db_exec "SELECT node_name, agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID';")
                    if [ -z "$NODE_DATA" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 您名下暂无已登记的节点。"
                    else
                        render_msg "$CHAT_ID" "$MSG_ID" "📢 **司令部指令下达：正在召唤所有哨兵回传简报...**%0A*(为防止触发 TG 官方限流，简报将排队依次送达，请耐心等待)*"
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME AIP APORT; do
                            call_agent "$NNAME" "$AIP" "$APORT" "/trigger_report" "" > /dev/null &
                            sleep 2  
                        done
                    fi
                    ;;

                "all_run")
                    # [引擎版] 唤醒全局巡逻: 对所有节点写入触发文件,引擎调度器排队执行
                    NODE_DATA=$(db_exec "SELECT node_name FROM nodes WHERE chat_id='$CHAT_ID' AND psk IS NOT NULL AND psk != '' AND IFNULL(engine_enabled,'true') != 'false';")
                    if [ -z "$NODE_DATA" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 您名下暂无可调度的节点 (未注册/无 PSK/已暂停)。"
                    else
                        COUNT=0
                        echo "$NODE_DATA" | while IFS='|' read -r NNAME; do
                            [ -z "$NNAME" ] && continue
                            echo "all" > "${MASTER_DIR}/.engine_state/${NNAME}.trigger"
                            COUNT=$((COUNT+1))
                        done
                        render_msg "$CHAT_ID" "$MSG_ID" "📢 **司令部指令下达：正在唤醒所有哨兵执行浏览器养护巡逻...**%0A*(各节点将由引擎按并发槽位排队执行,约 1 分钟内开始)*"
                    fi
                    ;;

                "/quality"|"/quality@"*)
                    TARGET_NODE=$(echo "$TEXT" | awk '{print $2}')
                    if [ -z "$TARGET_NODE" ]; then
                        send_msg "$CHAT_ID" "⚠️ 请指定目标节点。例如: \`/quality HK-1\`%0A或通过雷达面板进行选择操作。"
                    else
                        TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')
                        CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                        
                        AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                        AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                        AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                        if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                            render_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [quality] 指令，请稍候..."
                            
                            RESPONSE=$(call_agent "$TARGET_NODE" "$AGENT_IP" "$AGENT_PORT" "/trigger_quality" "")
                            
                            if [ "$RESPONSE" == "FAILED" ]; then
                                send_msg "$CHAT_ID" "❌ 指令下发超时或失败！请检查节点公网 IP 或防火墙端口 ($AGENT_PORT) 是否放行。"
                            elif [[ "$RESPONSE" == *"403"* ]]; then
                                send_msg "$CHAT_ID" "⚠️ **拒绝执行**：该节点未在本地开启此模块，请检查安装时的配置！"
                            else
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 回应: 🔍 深海声呐已投放！请等待异步战报回传。"
                            fi
                        else
                            render_msg "$CHAT_ID" "$MSG_ID" "❌ 数据库中未找到该节点的通讯地址。"
                        fi
                    fi
                    ;;

                "/trend"|"/trend@"*)
                    TARGET_NODE=$(echo "$TEXT" | awk '{print $2}')
                    if [ -z "$TARGET_NODE" ]; then
                        send_msg "$CHAT_ID" "⚠️ 请指定目标节点。例如: \`/trend HK-1\`%0A或通过雷达面板进行选择操作。"
                    else
                        TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')
                        CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                        
                        TREND_DATA=$(db_exec "SELECT datetime(check_time, 'localtime'), scam_score, goog_status, nf_status, gpt_status FROM ip_trend_log WHERE node_name='$TARGET_NODE' ORDER BY check_time DESC LIMIT 15;")
                        
                        if [ -z "$TREND_DATA" ]; then
                            render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 节点 \`$TARGET_NODE\` 暂无历史体检档案。请先执行 /quality 投放声呐进行探测。"
                        else
                            TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                            [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                            TEXT_RES="📈 *[${TARGET_ALIAS}] 历史态势感知 (近15次)*\n\n"
                            TEXT_RES+="时间(本地)  | 风险 | 谷歌 | NF | GPT\n"
                            TEXT_RES+="-----------------------------------------\n"
                            
                            while IFS='|' read -r c_time score goog nf gpt; do
                                [ -z "$score" ] && score="0"
                                [ -z "$goog" ] && goog="未知"
                                [ -z "$nf" ] && nf="未知"
                                [ -z "$gpt" ] && gpt="未知"
                                
                                short_time=$(echo "$c_time" | cut -c 6-16)
                                
                                if [ "$score" -le 20 ]; then SCORE_EMJ="🟢"
                                elif [ "$score" -le 60 ]; then SCORE_EMJ="🟡"
                                else SCORE_EMJ="🔴"
                                fi
                                
                                TEXT_RES+="\`${short_time}\` | ${SCORE_EMJ}\`${score}\` | \`${goog}\` | \`${nf}\` | \`${gpt}\`\n"
                            done <<< "$TREND_DATA"
                            TEXT_RES+="\n_💡 提示：🔴风险分 >60 极易触发网页验证码拦截；谷歌显示 CN 即为高危送中。_"
                            
                            BTNS="[[{\"text\":\"⚙️ 调出该节点控制台\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                            render_ui "$CHAT_ID" "$MSG_ID" "$TEXT_RES" "$BTNS"
                        fi
                    fi
                    ;;

                "list_nodes")
                    REGION_DATA=$(db_exec "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                    if [ -z "$REGION_DATA" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 您名下暂无已登记的节点，请先在边缘机执行部署。"
                    else
                        BTNS="["
                        while IFS='|' read -r REGION_NAME NODE_COUNT; do
                            [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                            FLAG=$(get_flag "$REGION_NAME")
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台已登记)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="$BTNS[{\"text\":\"🏠 回到司令部\",\"callback_data\":\"/start\"}]]"
                        render_ui "$CHAT_ID" "$MSG_ID" "🌍 **全视界战略雷达**\n已为您聚合当前舰队的部署大区，请选择要检阅的战区：" "$BTNS"
                    fi
                    ;;

                region:*)
                    TARGET_REGION=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    NODE_LIST=$(db_exec "SELECT node_name, IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND region='$TARGET_REGION';")
                    if [ -z "$NODE_LIST" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 该战区下暂无已登记的节点。"
                    else
                        BTNS="["
                        COL=0
                        ROW_STR="["
                        while IFS='|' read -r N_NAME N_ALIAS; do
                            [ -z "$N_NAME" ] && continue
                            ROW_STR="$ROW_STR{\"text\":\"🖥️ $N_ALIAS\",\"callback_data\":\"manage:$N_NAME\"},"
                            COL=$((COL+1))
                            if [ $COL -eq 2 ]; then
                                ROW_STR="${ROW_STR%,}]"
                                BTNS="$BTNS$ROW_STR,"
                                COL=0
                                ROW_STR="["
                            fi
                        done <<< "$NODE_LIST"
                        if [ $COL -eq 1 ]; then
                            ROW_STR="${ROW_STR%,}]"
                            BTNS="$BTNS$ROW_STR,"
                        fi
                        BTNS="$BTNS[{\"text\":\"⬅️ 返回战区地图\",\"callback_data\":\"list_nodes\"}, {\"text\":\"🏠 回到司令部\",\"callback_data\":\"/start\"}]]"
                        render_ui "$CHAT_ID" "$MSG_ID" "📍 **[$TARGET_REGION] 战区哨兵矩阵**\n请锁定要执行战术动作的具体目标：" "$BTNS"
                    fi
                    ;;

                manage:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                    TOGGLE_INFO=$(db_exec "SELECT enable_ota, agent_ip, IFNULL(last_seen, '未知') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    # 引擎版面板: engine_enabled 开关 + 两个触发按钮 (浏览器引擎实现)
                    ST_ENG=$(db_exec "SELECT IFNULL(engine_enabled,'true') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    TOGGLE_INFO=$(db_exec "SELECT enable_ota, agent_ip, IFNULL(last_seen, '未知') FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    ST_OTA=$(echo "$TOGGLE_INFO" | cut -d'|' -f1)
                    A_IP=$(echo "$TOGGLE_INFO" | cut -d'|' -f2)
                    LAST_SEEN=$(echo "$TOGGLE_INFO" | cut -d'|' -f3)

                    # [区域自检状态] (引擎会话落盘的判定)
                    REGION_STATE="(无)"
                    [ -f "${MASTER_DIR}/profiles/${TARGET_NODE}.region" ] && \
                        REGION_STATE=$(jq -r '.verdict + " (jump=" + (.jump // "?") + ")"' "${MASTER_DIR}/profiles/${TARGET_NODE}.region" 2>/dev/null)

                    # 触发按钮 (引擎版: 写触发文件, 调度器 45-90s 内执行)
                    BTN_ACTION="[{\"text\":\"📍 触发 Google 纠偏\",\"callback_data\":\"google:$TARGET_NODE\"}, {\"text\":\"🛡️ 触发信用净化\",\"callback_data\":\"trust:$TARGET_NODE\"}], [{\"text\":\"🔍 投放深海声呐 (查IP质量)\",\"callback_data\":\"quality:$TARGET_NODE\"}, {\"text\":\"📈 查看 IP 污染趋势图\",\"callback_data\":\"trend:$TARGET_NODE\"}], [{\"text\":\"📜 提取终端实时日志\",\"callback_data\":\"log:$TARGET_NODE\"}, {\"text\":\"📊 生成单机战报\",\"callback_data\":\"report:$TARGET_NODE\"}]"

                    # 引擎调度开关
                    if [ "$ST_ENG" != "false" ]; then
                        BTN_ENG="[{\"text\":\"🟢 浏览器养护: 开启中 (点击暂停)\",\"callback_data\":\"engine:$TARGET_NODE:false\"}]"
                        ENG_DESC="🟢 浏览器养护调度: 开启"
                    else
                        BTN_ENG="[{\"text\":\"🔴 浏览器养护: 已暂停 (点击恢复)\",\"callback_data\":\"engine:$TARGET_NODE:true\"}]"
                        ENG_DESC="🔴 浏览器养护调度: 已暂停"
                    fi

                    if [ "$IS_OFFICIAL_GATEWAY" != "true" ] && [ "$ST_OTA" == "true" ]; then
                        BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}, {\"text\":\"🆙 OTA 静默升级\",\"callback_data\":\"ota_confirm:$TARGET_NODE\"}]"
                    else
                        BTN_CONFIG="[{\"text\":\"✏️ 更改终端展示代号\",\"callback_data\":\"rename:$TARGET_NODE\"}]"
                    fi

                    BTN_DANGER="[{\"text\":\"🗑️ 从中枢销毁该档案\",\"callback_data\":\"del_confirm:$TARGET_NODE\"}, {\"text\":\"⬅️ 返回战区列表\",\"callback_data\":\"list_nodes\"}]"

                    BTNS="[$BTN_ACTION, $BTN_ENG, $BTN_CONFIG, $BTN_DANGER]"
                    TEXT_MSG="⚙️ **目标锁定**: \`$TARGET_ALIAS\`\n(底层标识: \`$TARGET_NODE\`)\n🌐 IP 坐标: \`$A_IP\`\n🕒 档案登记时间: \`$LAST_SEEN\`\n\n🤖 $ENG_DESC\n📍 区域自检: $REGION_STATE\n\n请下达精确控制指令："

                    render_ui "$CHAT_ID" "$MSG_ID" "$TEXT_MSG" "$BTNS"
                    ;;

                google:*|trust:*)
                    # [引擎版触发] 写触发文件, 引擎调度器 45-90s 内执行对应侧重会话
                    FOCUS=$(echo "$TEXT" | cut -d':' -f1)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')

                    VALID_OWNER=$(db_exec "SELECT 1 FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    if [ "$VALID_OWNER" == "1" ]; then
                        mkdir -p "${MASTER_DIR}/.engine_state"
                        echo "$FOCUS" > "${MASTER_DIR}/.engine_state/${TARGET_NODE}.trigger"
                        if [ "$FOCUS" == "google" ]; then
                            render_msg "$CHAT_ID" "$MSG_ID" "✅ **已下令**: 节点 \`$TARGET_NODE\` 即将执行 📍 Google 区域纠偏会话。%0A*(浏览器引擎将在约 1 分钟内启动,完成后区域自检自动落盘)*"
                        else
                            render_msg "$CHAT_ID" "$MSG_ID" "✅ **已下令**: 节点 \`$TARGET_NODE\` 即将执行 🛡️ IP 信用净化会话。%0A*(浏览器引擎将在约 1 分钟内启动,对区域白名单站点深访)*"
                        fi
                    fi
                    ;;

                engine:*)
                    # [引擎版开关] 节点级暂停/恢复浏览器养护调度
                    IFS=':' read -r CMD TARGET_NODE NEW_STATE <<< "$TEXT"
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    TARGET_NODE=$(echo "$TARGET_NODE" | tr -cd 'a-zA-Z0-9_.-')

                    VALID_OWNER=$(db_exec "SELECT 1 FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    if [ "$VALID_OWNER" == "1" ] && [[ "$NEW_STATE" =~ ^(true|false)$ ]]; then
                        db_exec "UPDATE nodes SET engine_enabled='$NEW_STATE' WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                        if [ "$NEW_STATE" == "true" ]; then
                            render_msg "$CHAT_ID" "$MSG_ID" "🟢 节点 \`$TARGET_NODE\` 浏览器养护调度已恢复。"
                        else
                            render_msg "$CHAT_ID" "$MSG_ID" "🔴 节点 \`$TARGET_NODE\` 浏览器养护调度已暂停 (进行中的会话不受影响,后续不再自动调度)。"
                        fi
                    fi
                    ;;

                del_confirm:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"
                    
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确定永久销毁该档案\",\"callback_data\":\"del_execute:$TARGET_NODE\"}], [{\"text\":\"取消操作\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                    WARNING_MSG="☢️ **【高危操作：销毁节点档案】**\n\n您即将从司令部彻底抹除节点 \`$TARGET_ALIAS\` 的追踪数据。\n\n⚠️ **风险提示**：\n1. 中枢数据库将永久丢失该节点的存活记录与 IP 污染体检趋势历史。\n2. 若边缘节点的 Agent 进程仍在运行，其下一次发送探测报告时将因未注册被司令部抛弃。\n\n**是否确定执行销毁动作？**"
                    
                    render_ui "$CHAT_ID" "$MSG_ID" "$WARNING_MSG" "$CONFIRM_BTNS"
                    ;;

                del_execute:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    VALID_OWNER=$(db_exec "SELECT 1 FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    
                    if [ "$VALID_OWNER" == "1" ]; then
                        db_exec "DELETE FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                        db_exec "DELETE FROM ip_trend_log WHERE node_name='$TARGET_NODE';"
                        
                        render_msg "$CHAT_ID" "$MSG_ID" "🗑️ 节点 \`$TARGET_NODE\` 的档案及历史污染趋势已从司令部彻底销毁！"
                    else
                        render_msg "$CHAT_ID" "$MSG_ID" "⛔ **安全拦截**：销毁失败。目标节点不存在或您无权越权操作！"
                        continue
                    fi
                    
                    REGION_DATA=$(db_exec "SELECT region, COUNT(*) FROM nodes WHERE chat_id='$CHAT_ID' GROUP BY region;")
                    if [ -z "$REGION_DATA" ]; then
                        send_msg "$CHAT_ID" "⚠️ 当前司令部已无任何节点挂载。"
                    else
                        BTNS="["
                        while IFS='|' read -r REGION_NAME NODE_COUNT; do
                            [ -z "$REGION_NAME" ] && REGION_NAME="UNKNOWN"
                            FLAG=$(get_flag "$REGION_NAME")
                            BTNS="$BTNS[{\"text\":\"$FLAG $REGION_NAME ($NODE_COUNT 台已登记)\",\"callback_data\":\"region:$REGION_NAME\"}],"
                        done <<< "$REGION_DATA"
                        BTNS="$BTNS[{\"text\":\"🏠 回到司令部\",\"callback_data\":\"/start\"}]]"
                        send_ui "$CHAT_ID" "🌍 刷新后的全视界雷达：" "$BTNS"
                    fi
                    ;;

                rename:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    curl -s -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
                        -H "Content-Type: application/json" \
                        -d "{\"chat_id\":\"$CHAT_ID\",\"text\":\"✏️ 请回复本消息以重命名节点:\n\`$TARGET_NODE\`\n(仅限中英文、数字，最长20字符)\",\"parse_mode\":\"Markdown\",\"reply_markup\":{\"force_reply\":true}}" > /dev/null
                    ;;

                do_rename:*)
                    IFS=':' read -r CMD TARGET_NODE NEW_ALIAS <<< "$TEXT"
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在向 \`$TARGET_NODE\` 下发重命名指令，正在建立加密隧道..."
                        
                        ALIAS_B64=$(echo -n "$NEW_ALIAS" | base64 | tr -d '\n' | tr '+/' '-_')
                        RESPONSE=$(call_agent "$TARGET_NODE" "$AGENT_IP" "$AGENT_PORT" "/trigger_rename" "b64=${ALIAS_B64}")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            send_msg "$CHAT_ID" "❌ 指令下发超时！为防范劫持风险，已终止请求。"
                        elif [[ "$RESPONSE" == *"Action Accepted"* ]]; then
                            db_exec "UPDATE nodes SET node_alias='$NEW_ALIAS' WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE';"
                            send_msg "$CHAT_ID" "✅ 通讯成功！节点别名已下发: \`$NEW_ALIAS\`%0A*(司令部档案已自动刷新，雷达面板已同步)*"
                        else
                            send_msg "$CHAT_ID" "⚠️ 节点拒绝了请求，请确保 Agent 已更新至 v3.5.2%0A(回传信息: \`${RESPONSE}\`)"
                        fi
                    else
                        render_msg "$CHAT_ID" "$MSG_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                ota_confirm:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CONFIRM_BTNS="[[{\"text\":\"🚨 确认执行远程升级\",\"callback_data\":\"ota_execute:$TARGET_NODE\"}], [{\"text\":\"取消\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                    render_ui "$CHAT_ID" "$MSG_ID" "☢️ **操作确认**：即将向 \`$TARGET_NODE\` 下发 OTA 热更新指令。\n节点更新完成后会自动发送包含新版本号的注册回执，确定执行？" "$CONFIRM_BTNS"
                    ;;

                ota_execute:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在向 \`$TARGET_NODE\` 发送 OTA 触发报文..."
                        
                        RESPONSE=$(call_agent "$TARGET_NODE" "$AGENT_IP" "$AGENT_PORT" "/trigger_ota" "")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            send_msg "$CHAT_ID" "❌ OTA 指令下发彻底失败！链路异常或严禁使用 HTTP 降级通讯。"
                        elif [[ "$RESPONSE" == *"403"* ]]; then
                            send_msg "$CHAT_ID" "⚠️ **节点拒绝执行**：该节点本地未开启 OTA 权限或运行在官方网关下！"
                        else
                            send_msg "$CHAT_ID" "✅ OTA (TLS加密) 触发成功！节点正在后台执行拉取重构..."
                        fi
                    else
                        render_msg "$CHAT_ID" "$MSG_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;

                report:*|log:*|quality:*)
                    ACTION_TYPE=$(echo "$TEXT" | cut -d':' -f1)
                    TARGET_NODE=$(echo "$TEXT" | cut -d':' -f2 | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    AGENT_INFO=$(db_exec "SELECT agent_ip, agent_port FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                    AGENT_IP=$(echo "$AGENT_INFO" | cut -d'|' -f1)
                    AGENT_PORT=$(echo "$AGENT_INFO" | cut -d'|' -f2)

                    if [ -n "$AGENT_IP" ] && [ -n "$AGENT_PORT" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⏳ 正在向 \`$TARGET_NODE\` ($AGENT_IP) 下发 [$ACTION_TYPE] 指令，请稍候..."
                        
                        RESPONSE=$(call_agent "$TARGET_NODE" "$AGENT_IP" "$AGENT_PORT" "/trigger_${ACTION_TYPE}" "")
                        
                        if [ "$RESPONSE" == "FAILED" ]; then
                            send_msg "$CHAT_ID" "❌ 指令下发超时或失败！为保护链路安全，已终止通信 (严禁降级为 HTTP)。"
                        elif [[ "$RESPONSE" == *"403"* ]]; then
                            send_msg "$CHAT_ID" "⚠️ **拒绝执行**：该节点未在本地开启此模块，请检查安装时的配置！"
                        else
                            if [ "$ACTION_TYPE" == "quality" ]; then
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 回应: 🔍 深海声呐已投放！请等待异步战报回传。"
                            elif [ "$ACTION_TYPE" == "log" ]; then
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 正在抓取日志..."
                            else
                                send_msg "$CHAT_ID" "✅ 节点 \`$TARGET_NODE\` 接收指令: $ACTION_TYPE"
                            fi
                        fi
                    else
                        render_msg "$CHAT_ID" "$MSG_ID" "❌ 数据库中未找到该节点的通讯地址。"
                    fi
                    ;;


                trend:*)
                    TARGET_NODE=$(echo "${TEXT#*:}" | tr -cd 'a-zA-Z0-9_.-')
                    CHAT_ID=$(echo "$CHAT_ID" | tr -cd '0-9-')
                    
                    TREND_DATA=$(db_exec "SELECT datetime(check_time, 'localtime'), scam_score, goog_status, nf_status, gpt_status FROM ip_trend_log WHERE node_name='$TARGET_NODE' ORDER BY check_time DESC LIMIT 15;")
                    
                    if [ -z "$TREND_DATA" ]; then
                        render_msg "$CHAT_ID" "$MSG_ID" "⚠️ 节点 \`$TARGET_NODE\` 暂无历史体检档案。请先执行 [🔍 投放深海声呐] 进行探测。"
                    else
                        TARGET_ALIAS=$(db_exec "SELECT IFNULL(node_alias, node_name) FROM nodes WHERE chat_id='$CHAT_ID' AND node_name='$TARGET_NODE' LIMIT 1;")
                        [ -z "$TARGET_ALIAS" ] && TARGET_ALIAS="$TARGET_NODE"

                        TEXT_RES="📈 *[${TARGET_ALIAS}] 历史态势感知 (近15次)*\n\n"
                        TEXT_RES+="时间(本地)  | 风险 | 谷歌 | NF | GPT\n"
                        TEXT_RES+="-----------------------------------------\n"
                        
                        while IFS='|' read -r c_time score goog nf gpt; do
                            [ -z "$score" ] && score="0"
                            [ -z "$goog" ] && goog="未知"
                            [ -z "$nf" ] && nf="未知"
                            [ -z "$gpt" ] && gpt="未知"
                            
                            short_time=$(echo "$c_time" | cut -c 6-16)
                            
                            if [ "$score" -le 20 ]; then SCORE_EMJ="🟢"
                            elif [ "$score" -le 60 ]; then SCORE_EMJ="🟡"
                            else SCORE_EMJ="🔴"
                            fi
                            
                            TEXT_RES+="\`${short_time}\` | ${SCORE_EMJ}\`${score}\` | \`${goog}\` | \`${nf}\` | \`${gpt}\`\n"
                        done <<< "$TREND_DATA"
                        TEXT_RES+="\n_💡 提示：🔴风险分 >60 极易触发网页验证码拦截；谷歌显示 CN 即为高危送中。_"
                        
                        BTNS="[[{\"text\":\"⚙️ 调出该节点控制台\",\"callback_data\":\"manage:$TARGET_NODE\"}]]"
                        render_ui "$CHAT_ID" "$MSG_ID" "$TEXT_RES" "$BTNS"
                    fi
                    ;;
                    
            esac
        done
    fi
    sleep 1
done