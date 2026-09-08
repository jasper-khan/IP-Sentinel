#!/bin/bash
# ==========================================================
# 脚本名称: tg_digest.sh (Master 侧每日养护简报)
# 核心功能: 聚合浏览器引擎养护活动 (engine.log + profiles/*.region + DB),
#           按 chat_id 分组, 每日一条 TG 简报发给各管理员。
# 背景: 上游 agent 侧 curl 养护简报的 Master 引擎版重建 —— curl 退役后
#       养护数据搬到 Master 引擎, agent 本地日报已无养护统计。
# ==========================================================
CONF="/opt/ip_sentinel_master/master.conf"
[ -f "$CONF" ] || exit 1
source "$CONF"
[ -z "$TG_TOKEN" ] && exit 0

MASTER_DIR="${MASTER_DIR:-/opt/ip_sentinel_master}"
DB_FILE="${DB_FILE:-${MASTER_DIR}/sentinel.db}"
LOG="${MASTER_DIR}/logs/engine.log"
PROFILES="${MASTER_DIR}/profiles"

db_exec() { printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"; }
send() {
    curl -s --connect-timeout 5 -m 15 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" --data-urlencode "text=$2" -d "parse_mode=Markdown" >/dev/null 2>&1
}
verdict_emoji() {
    case "$1" in
        OK) echo "🟢" ;; WATCH) echo "🟡" ;; DRIFT) echo "🟠" ;;
        SINICIZED) echo "🔴" ;; *) echo "⚪" ;;
    esac
}

# 时间戳串按 "YYYY-MM-DD HH:MM:SS" 字典序=时序, 直接字符串比较即可
CUTOFF=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
[ -z "$CUTOFF" ] && CUTOFF="0000-00-00 00:00:00"
TODAY=$(date -u '+%Y-%m-%d')

CHATS=$(db_exec "SELECT DISTINCT chat_id FROM nodes WHERE psk IS NOT NULL AND psk!='';")
for chat in $CHATS; do
    [ -z "$chat" ] && continue
    NODES=$(db_exec "SELECT node_name, IFNULL(node_alias,node_name), IFNULL(region,'?'), IFNULL(agent_ip,'?') FROM nodes WHERE chat_id='$chat' AND psk IS NOT NULL AND psk!='';")
    [ -z "$NODES" ] && continue

    TOTAL=0; FLAG=0; N=0; BODY=""
    while IFS='|' read -r n alias region ip; do
        [ -z "$n" ] && continue
        N=$((N+1))
        # 24h 会话统计 (从调度器 "本轮会话结束 (rc=N)" 行按时间戳过滤)
        stats=$(awk -v n="$n" -v cut="$CUTOFF" '
            { ts=substr($0,2,19) }
            ts >= cut && index($0, "节点 " n " 本轮会话结束")>0 { t++; if(index($0,"(rc=0)")>0) o++ }
            END{ print (t+0)"|"(o+0) }' "$LOG" 2>/dev/null)
        sess=${stats%|*}; ok=${stats#*|}
        [ -z "$sess" ] && sess=0; [ -z "$ok" ] && ok=0
        TOTAL=$((TOTAL+sess))
        # 时区 (最新 "启动会话 ... tz=" 行)
        tz=$(grep "启动会话" "$LOG" 2>/dev/null | grep -F "[$n]" | tail -1 | grep -o 'tz=[^ ]*' | cut -d= -f2)
        [ -z "$tz" ] && tz="?"
        # 最新区域自检结论
        RF="${PROFILES}/${n}.region"; verdict="未检测"
        if [ -f "$RF" ]; then
            v=$(sed -n 's/.*"verdict": *"\([^"]*\)".*/\1/p' "$RF")
            [ -n "$v" ] && verdict="$v"
        fi
        em=$(verdict_emoji "$verdict")
        [ "$verdict" != "OK" ] && [ "$verdict" != "未检测" ] && FLAG=$((FLAG+1))
        showip=$(echo "$ip" | tr '_' ' ' | awk '{print $1}')
        BODY="${BODY}
${em} *${alias}* (${region})
   IP \`${showip}\` · tz \`${tz}\`
   24h养护 ${sess} 次 (成功 ${ok}) · 自检 ${verdict}"
    done <<< "$NODES"

    ALERT=""
    [ "$FLAG" -gt 0 ] && ALERT="
⚠️ *${FLAG} 个节点自检异常, 请留意*"
    MSG="🛡️ *IP-Sentinel 每日养护简报*
📅 ${TODAY} UTC · 节点 ${N} 台 · 24h养护 ${TOTAL} 次${ALERT}
━━━━━━━━━━━━━━━${BODY}"
    send "$chat" "$MSG"
done
