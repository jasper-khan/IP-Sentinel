#!/bin/bash
# ==========================================================
# 脚本名称: tg_digest.sh (Master 侧每日养护简报)
# 核心功能: 聚合浏览器引擎养护活动 (engine.log + profiles/*.region + DB),
#           按 chat_id 分组, 每日一条 TG 简报发给各管理员。
# 背景: 上游 agent 侧 curl 养护简报的 Master 引擎版重建 —— 产品语义不变
#       (Google 区域纠偏 / IP 信用净化), 仅执行引擎由 curl 换为 Camoufox。
# DIGEST_DRYRUN=1 则打印不发送 (预览)。
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
    if [ "${DIGEST_DRYRUN:-0}" = "1" ]; then printf '\n===== chat=%s =====\n%s\n' "$1" "$2"; return; fi
    curl -s --connect-timeout 5 -m 15 -X POST \
        "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
        -d "chat_id=$1" --data-urlencode "text=$2" -d "parse_mode=Markdown" >/dev/null 2>&1
}
get_flag() {
    case "$(echo "$1" | tr 'a-z' 'A-Z')" in
        US) echo "🇺🇸";; HK) echo "🇭🇰";; TW) echo "🇹🇼";; JP) echo "🇯🇵";; SG) echo "🇸🇬";;
        UK|GB) echo "🇬🇧";; DE) echo "🇩🇪";; FR) echo "🇫🇷";; NL) echo "🇳🇱";; CA) echo "🇨🇦";;
        AU) echo "🇦🇺";; KR) echo "🇰🇷";; IN) echo "🇮🇳";; MO) echo "🇲🇴";; VN) echo "🇻🇳";;
        TH) echo "🇹🇭";; MY) echo "🇲🇾";; PH) echo "🇵🇭";; ID) echo "🇮🇩";; TR) echo "🇹🇷";;
        AE) echo "🇦🇪";; SA) echo "🇸🇦";; ES) echo "🇪🇸";; BG) echo "🇧🇬";; NG) echo "🇳🇬";;
        *) echo "🌐";;
    esac
}
verdict_emoji() {
    case "$1" in OK) echo "🟢";; WATCH) echo "🟡";; DRIFT) echo "🟠";; SINICIZED) echo "🔴";; *) echo "⚪";; esac
}

CUTOFF=$(date -u -d '24 hours ago' '+%Y-%m-%d %H:%M:%S' 2>/dev/null)
[ -z "$CUTOFF" ] && CUTOFF="0000-00-00 00:00:00"
TODAY=$(date -u '+%Y-%m-%d')
GEN=$(date -u '+%Y-%m-%d %H:%M UTC')
DIV="───────────────────────"

CHATS=$(db_exec "SELECT DISTINCT chat_id FROM nodes WHERE psk IS NOT NULL AND psk!='';")
for chat in $CHATS; do
    [ -z "$chat" ] && continue
    NODES=$(db_exec "SELECT node_name, IFNULL(node_alias,node_name), IFNULL(region,'?'), IFNULL(agent_ip,'?') FROM nodes WHERE chat_id='$chat' AND psk IS NOT NULL AND psk!='';")
    [ -z "$NODES" ] && continue

    GTOTAL=0; TTOTAL=0; FLAG=0; N=0; CARDS=""
    while IFS='|' read -r n alias region ip; do
        [ -z "$n" ] && continue
        N=$((N+1))
        # 一遍扫 24h: 会话数 / 区域自检达成 / 白名单深访
        read sess okv badv trust <<< "$(awk -v n="$n" -v cut="$CUTOFF" '
            { ts=substr($0,2,19) }
            ts < cut { next }
            index($0,"节点 " n " 本轮会话结束")>0 { sess++ }
            index($0,"[" n "]")>0 {
                if (index($0,"区域自检:")>0) { if(index($0,"-> OK")>0) okv++; else badv++ }
                if (index($0,"白名单站点完成")>0) trust++
            }
            END { print (sess+0), (okv+0), (badv+0), (trust+0) }' "$LOG" 2>/dev/null)"
        totv=$((okv+badv)); GTOTAL=$((GTOTAL+sess)); TTOTAL=$((TTOTAL+trust))
        gr="—"; [ "$totv" -gt 0 ] && gr=$(awk "BEGIN{printf \"%.0f\", ($okv/$totv)*100}")
        # 时区 + 城市
        tz=$(grep "启动会话" "$LOG" 2>/dev/null | grep -F "[$n]" | tail -1 | grep -o 'tz=[^ ]*' | cut -d= -f2)
        [ -z "$tz" ] && tz="?"
        city=""; [ "$tz" != "?" ] && city=$(echo "$tz" | awk -F/ '{print $NF}' | tr '_' ' ')
        # 最新自检落盘
        RF="${PROFILES}/${n}.region"; verdict="未检测"; jump=""; lastchk=""
        if [ -f "$RF" ]; then
            v=$(sed -n 's/.*"verdict": *"\([^"]*\)".*/\1/p' "$RF"); [ -n "$v" ] && verdict="$v"
            jump=$(sed -n 's/.*"jump": *"\([^"]*\)".*/\1/p' "$RF")
            rts=$(sed -n 's/.*"ts": *\([0-9]*\).*/\1/p' "$RF")
            [ -n "$rts" ] && lastchk=$(date -u -d "@$rts" '+%m-%d %H:%M UTC' 2>/dev/null)
        fi
        em=$(verdict_emoji "$verdict")
        [ "$verdict" != "OK" ] && [ "$verdict" != "未检测" ] && FLAG=$((FLAG+1))
        showip=$(echo "$ip" | tr '_' ' ' | awk '{print $1}')
        fl=$(get_flag "$region"); loc="$region"; [ -n "$city" ] && loc="$region / $city"

        # Google 区域纠偏行
        if [ "$totv" -gt 0 ]; then
            gline="🎯 *Google 区域纠偏*: 24h ${sess} 次 · 达成率 *${gr}%* (✅${okv} 🔴${badv})"
        elif [ "$sess" -gt 0 ]; then
            gline="🎯 *Google 区域纠偏*: 24h ${sess} 次"
        else
            gline="🎯 *Google 区域纠偏*: 近 24h 无会话 (调度 90min/轮)"
        fi
        # 自检详情行
        if [ "$verdict" = "未检测" ]; then
            vline="   最近自检: ⚪ 未检测"
        else
            vline="   最近自检: ${em} ${verdict} · jump ${jump:-?} · ${lastchk:-?}"
        fi
        card="${fl} *${alias}*  ·  ${loc}
📡 出口 IP: \`${showip}\`  ·  🕐 \`${tz}\`
${gline}
${vline}
🔰 *IP 信用净化*: 24h 深访白名单 ${trust} 次"
        [ -n "$CARDS" ] && CARDS="${CARDS}
${DIV}"
        CARDS="${CARDS}
${card}"
    done <<< "$NODES"

    ALERT=""; [ "$FLAG" -gt 0 ] && ALERT="
⚠️ *${FLAG} 个节点区域异常 (送中/漂移), 请留意*"
    MSG="📊 *IP-Sentinel 每日养护简报*
📅 ${TODAY} UTC · 节点 ${N} 台 · 🎯纠偏 ${GTOTAL} 次 · 🔰净化 ${TTOTAL} 次${ALERT}
═══════════════════════${CARDS}
═══════════════════════
⏱️ 战报生成 \`${GEN}\` · 引擎 v${MASTER_VERSION:-?}"
    send "$chat" "$MSG"
done
