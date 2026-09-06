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

ENGINE_CONCURRENCY="${ENGINE_CONCURRENCY:-2}"
ENGINE_MIN_INTERVAL="${ENGINE_MIN_INTERVAL:-5400}"
SESSION_TIMEOUT=1800

mkdir -p "${STATE_DIR}" "${MASTER_DIR}/logs"

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [Schedul] $*" >> "$LOG_FILE"
}

db_exec() {
    printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"
}

# 节点端口查询 (隧道管理器维护的持久映射)
node_port() {
    awk -F'|' -v n="$1" '$1 == n {print $2}' "$PORT_MAP_FILE" 2>/dev/null | head -n 1
}

# 活跃会话计数 (每个会话 = 一个 camoufox_session.py 进程)
active_sessions() {
    pgrep -fc "camoufox_session.py" 2>/dev/null || echo 0
}

# 该节点是否已有会话在跑 (同节点永不双开)
node_running() {
    pgrep -f -- "--node $1 " >/dev/null 2>&1
}

launch_session() {
    local n="$1" region="$2"
    local port
    port=$(node_port "$n")

    log "节点 ${n} 进入会话 (region=${region}, proxy=${port:-local})"

    (
        if [ -n "$port" ]; then
            timeout --signal=TERM "$SESSION_TIMEOUT" \
                "${VENV_PY}" "${ENGINE_DIR}/camoufox_session.py" \
                --node "$n" --region "$region" --socks-port "$port" >> /dev/null 2>&1
        else
            # 无端口映射: 同机节点 (Master=Agent 同装) 或隧道未就绪——本机出口
            timeout --signal=TERM "$SESSION_TIMEOUT" \
                "${VENV_PY}" "${ENGINE_DIR}/camoufox_session.py" \
                --node "$n" --region "$region" --socks-port 0 >> /dev/null 2>&1
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

log "========== 会话调度器启动 (并发=${ENGINE_CONCURRENCY}, 间隔=${ENGINE_MIN_INTERVAL}s) =========="

while true; do
    # 收割已退出子进程,防僵尸堆积
    wait -n 2>/dev/null || true

    NOW=$(date +%s)
    ACTIVE=$(active_sessions)
    SLOTS=$((ENGINE_CONCURRENCY - ACTIVE))

    if [ "$SLOTS" -gt 0 ]; then
        NODES=$(db_exec "SELECT node_name, region FROM nodes WHERE psk IS NOT NULL AND psk != '' ORDER BY last_seen DESC;")

        while IFS='|' read -r n region; do
            [ -z "$n" ] && continue
            [ "$SLOTS" -le 0 ] && break
            region="${region:-US}"

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

            launch_session "$n" "$region"
            SLOTS=$((SLOTS - 1))
        done <<< "$NODES"
    fi

    # 扫描间隔随机抖动
    sleep $((45 + RANDOM % 45))
done
