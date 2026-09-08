#!/bin/bash
# ==========================================================
# 脚本名称: scheduler.sh (浏览器引擎 · 会话调度器)
# 核心功能: 轮询数据库节点,持续驱动 Camoufox 会话,
#           借隧道出口对各节点 IP 执行拟人养护。
# 调度模型 (并行工作池):
#   - ENGINE_CONCURRENCY 个并发槽位,槽位空闲即补位
#     (非批处理: 不等待整轮最慢会话)
#   - 节点级最小间隔 ENGINE_MIN_INTERVAL 秒 (默认 5400 = 90 分钟)
#   - 单会话硬超时 1800s,防挂死占槽
#   - 节点在跑即跳过 (同节点永不双开)
#   - 扫描间隔带随机抖动,消除规律性唤醒特征
# ==========================================================

MASTER_DIR="${MASTER_DIR:-/opt/ip_sentinel_master}"
DB_FILE="${DB_FILE:-${MASTER_DIR}/sentinel.db}"
ENGINE_DIR="${MASTER_DIR}/engine"
VENV_PY="${MASTER_DIR}/venv/bin/python3"
LOG_FILE="${MASTER_DIR}/logs/engine.log"
STATE_DIR="${MASTER_DIR}/.engine_state"
PORT_MAP_FILE="${MASTER_DIR}/.tunnel_ports"
KEYWORDS_DIR="${MASTER_DIR}/data/keywords"
WHITELIST_DIR="${MASTER_DIR}/data/whitelist"
REPO_RAW_URL="https://raw.githubusercontent.com/jasper-khan/IP-Sentinel/main"

ENGINE_CONCURRENCY="${ENGINE_CONCURRENCY:-2}"
ENGINE_MIN_INTERVAL="${ENGINE_MIN_INTERVAL:-5400}"
SESSION_TIMEOUT=1800

mkdir -p "${STATE_DIR}" "${MASTER_DIR}/logs" "${KEYWORDS_DIR}" "${WHITELIST_DIR}"

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [Schedul] $*" >> "$LOG_FILE"
}

db_exec() {
    printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"
}

# [persona 配套] 节点区域关键词缺失时按需拉取 (数据文件,非执行内容)
ensure_keywords() {
    local region="$1"
    local kw_file="${KEYWORDS_DIR}/kw_${region}.txt"
    [ -s "$kw_file" ] && return 0
    curl -fsSL --connect-timeout 10 --retry 2 "${REPO_RAW_URL}/data/keywords/kw_${region}.txt" \
        -o "$kw_file" 2>/dev/null || { rm -f "$kw_file"; log "WARN kw_${region}.txt 拉取失败,会话将无关键词"; }
}

# [persona 配套] 节点区域白名单 (IP 信用净化深访目标) 缺失时按需拉取
ensure_whitelist() {
    local region="$1"
    local wl_file="${WHITELIST_DIR}/wl_${region}.txt"
    [ -s "$wl_file" ] && return 0
    curl -fsSL --connect-timeout 10 --retry 2 "${REPO_RAW_URL}/data/whitelist/wl_${region}.txt" \
        -o "$wl_file" 2>/dev/null || { rm -f "$wl_file"; log "WARN wl_${region}.txt 拉取失败,净化将无白名单"; }
}

# 节点端口查询 (隧道管理器维护的持久映射)
node_port() {
    awk -F'|' -v n="$1" '$1 == n {print $2}' "$PORT_MAP_FILE" 2>/dev/null | head -n 1
}

# 活跃会话计数 (每个会话 = 一个 camoufox_session.py 进程)
# pgrep -fc 无匹配时输出空且 exit 1 → || echo 0 会产生第二行;只取首行数字
active_sessions() {
    local n
    n=$(pgrep -fc "camoufox_session.py" 2>/dev/null)
    [ -z "$n" ] && n=0
    echo "$n"
}

# 该节点是否已有会话在跑 (同节点永不双开)
node_running() {
    pgrep -f -- "--node $1 " >/dev/null 2>&1
}

# 本机公网 IP (判定同机节点直连;与 tunnel_manager 同逻辑)
LOCAL_EGRESS_IP=$(curl -4 -s -m 5 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')

is_local_node() {
    local addr="$1"
    local first
    first=$(echo "$addr" | tr '_' ',' | cut -d',' -f1)
    [[ "$first" == 127.0.0.1 || "$first" == ::1 ]] && return 0
    [ -n "$LOCAL_EGRESS_IP" ] && [ "$first" == "$LOCAL_EGRESS_IP" ] && return 0
    return 1
}

launch_session() {
    local n="$1" region="$2" lang_params="$3" lat="$4" lon="$5" node_ip="$6" focus="$7"
    local port
    port=$(node_port "$n")

    # 同机节点: 无视端口映射,直接本机出口 (隧道池已跳过其隧道)
    if is_local_node "$node_ip"; then
        port=""
    fi

    ensure_keywords "$region"
    ensure_whitelist "$region"

    log "节点 ${n} 进入会话 (focus=${focus:-all}, region=${region}, proxy=${port:-local})"

    local extra_args=()
    [ -n "$lang_params" ] && extra_args+=(--lang-params "$lang_params")
    [ -n "$lat" ] && extra_args+=(--lat "$lat")
    [ -n "$lon" ] && extra_args+=(--lon "$lon")
    [ -n "$focus" ] && extra_args+=(--focus "$focus")

    (
        if [ -n "$port" ]; then
            timeout --signal=TERM "$SESSION_TIMEOUT" \
                "${VENV_PY}" "${ENGINE_DIR}/camoufox_session.py" \
                --node "$n" --region "$region" --socks-port "$port" "${extra_args[@]}" >> /dev/null 2>&1
        else
            # 无端口映射: 同机节点 (Master=Agent 同装) 或隧道未就绪——本机出口
            timeout --signal=TERM "$SESSION_TIMEOUT" \
                "${VENV_PY}" "${ENGINE_DIR}/camoufox_session.py" \
                --node "$n" --region "$region" --socks-port 0 "${extra_args[@]}" >> /dev/null 2>&1
        fi
        RC=$?
        echo "$(date +%s)" > "${STATE_DIR}/${n}.last"
        if [ "$RC" -eq 124 ]; then
            log "节点 ${n} 会话超时被终止 (${SESSION_TIMEOUT}s),槽位已释放"
        else
            log "节点 ${n} 本轮会话结束 (rc=${RC})"
        fi
    ) &
    disown
}

# [手动触发队列] TG 按钮写 <node>.trigger (内容=focus),调度器消费:
# 优先于间隔门禁,但仍受并发槽位与同节点互斥约束
consume_trigger() {
    local n="$1" region="$2" lp="$3" lat="$4" lon="$5" ip="$6"
    local trig="${STATE_DIR}/${n}.trigger"
    [ -f "$trig" ] || return 1
    local focus
    focus=$(cat "$trig" 2>/dev/null | head -n 1 | tr -cd 'a-z')
    [ -z "$focus" ] && focus="all"
    rm -f "$trig"
    if node_running "$n"; then
        log "节点 ${n} 手动触发: 会话进行中,触发并入下一轮"
        return 1
    fi
    launch_session "$n" "$region" "$lp" "$lat" "$lon" "$ip" "$focus"
    return 0
}

log "========== 会话调度器启动 (并发=${ENGINE_CONCURRENCY}, 间隔=${ENGINE_MIN_INTERVAL}s) =========="

while true; do
    # 收割已退出子进程,防僵尸堆积
    wait -n 2>/dev/null || true

    NOW=$(date +%s)
    ACTIVE=$(active_sessions)
    SLOTS=$((ENGINE_CONCURRENCY - ACTIVE))

    if [ "$SLOTS" -gt 0 ]; then
        NODES=$(db_exec "SELECT node_name, region, IFNULL(lang_params,''), IFNULL(base_lat,''), IFNULL(base_lon,''), IFNULL(agent_ip,'') FROM nodes WHERE psk IS NOT NULL AND psk != '' AND IFNULL(engine_enabled,'true') != 'false' ORDER BY last_seen DESC;")

        while IFS='|' read -r n region lang_params lat lon node_ip; do
            [ -z "$n" ] && continue
            [ "$SLOTS" -le 0 ] && break
            region="${region:-US}"

            # 手动触发优先 (TG 按钮),不受间隔门禁限制
            if consume_trigger "$n" "$region" "$lang_params" "$lat" "$lon" "$node_ip"; then
                SLOTS=$((SLOTS - 1))
                continue
            fi

            # 同节点在跑即跳过
            if node_running "$n"; then
                continue
            fi

            # 节点级最小间隔门禁
            LAST=0
            [ -f "${STATE_DIR}/${n}.last" ] && LAST=$(cat "${STATE_DIR}/${n}.last")
            AGE=$((NOW - LAST))
            if [ "$AGE" -lt "$ENGINE_MIN_INTERVAL" ]; then
                continue
            fi

            launch_session "$n" "$region" "$lang_params" "$lat" "$lon" "$node_ip" "all"
            SLOTS=$((SLOTS - 1))
        done <<< "$NODES"
    fi

    # 扫描间隔随机抖动
    sleep $((45 + RANDOM % 45))
done
