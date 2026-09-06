#!/bin/bash
# ==========================================================
# 脚本名称: scheduler.sh (浏览器引擎 · 会话调度器)
# 核心功能: 轮询数据库节点,依次(或低并发)驱动 Camoufox 会话,
#           借隧道出口对各节点 IP 执行拟人养护。
# 调度模型:
#   - 每轮扫描全部在线节点,按注册顺序执行
#   - 并发度 ENGINE_CONCURRENCY (默认 1=串行; 2C2G 建议 1-2)
#   - 节点级最小间隔 ENGINE_MIN_INTERVAL 秒 (默认 5400 = 90 分钟)
#   - 会话级随机抖动,避免规律性唤醒特征
# ==========================================================

MASTER_DIR="${MASTER_DIR:-/opt/ip_sentinel_master}"
DB_FILE="${DB_FILE:-${MASTER_DIR}/sentinel.db}"
ENGINE_DIR="${MASTER_DIR}/engine"
VENV_PY="${MASTER_DIR}/venv/bin/python3"
LOG_FILE="${MASTER_DIR}/logs/engine.log"
STATE_DIR="${MASTER_DIR}/.engine_state"
PORT_MAP_FILE="${MASTER_DIR}/.tunnel_ports"

ENGINE_CONCURRENCY="${ENGINE_CONCURRENCY:-1}"
ENGINE_MIN_INTERVAL="${ENGINE_MIN_INTERVAL:-5400}"

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

run_session() {
    local n="$1" region="$2"
    local port
    port=$(node_port "$n")
    if [ -z "$port" ]; then
        log "节点 ${n} 无隧道端口映射 (同机节点或隧道未就绪),尝试本机出口模式"
        # 同机 Agent (Master=Agent 同装): 直接本机出口,端口占位 0 表示不走 SOCKS
        port=0
    fi

    if [ "$port" = "0" ]; then
        # 同机模式: 不带 --socks-port 参数由会话脚本直连 (出口即本机)
        "${VENV_PY}" "${ENGINE_DIR}/camoufox_session.py" \
            --node "$n" --region "$region" --socks-port 0 >> /dev/null 2>&1
    else
        "${VENV_PY}" "${ENGINE_DIR}/camoufox_session.py" \
            --node "$n" --region "$region" --socks-port "$port" >> /dev/null 2>&1
    fi
    echo "$(date +%s)" > "${STATE_DIR}/${n}.last"
    log "节点 ${n} 本轮会话结束 (region=${region})"
}

log "========== 会话调度器启动 (并发=${ENGINE_CONCURRENCY}) =========="

while true; do
    # 随机抖动开场,消除固定周期特征
    sleep $((120 + RANDOM % 300))

    NOW=$(date +%s)
    RUNNING=0

    NODES=$(db_exec "SELECT node_name, region FROM nodes WHERE psk IS NOT NULL AND psk != '' ORDER BY last_seen DESC;")

    while IFS='|' read -r n region; do
        [ -z "$n" ] && continue
        region="${region:-US}"

        # 节点级最小间隔门禁
        LAST=0
        [ -f "${STATE_DIR}/${n}.last" ] && LAST=$(cat "${STATE_DIR}/${n}.last")
        AGE=$((NOW - LAST))
        if [ "$AGE" -lt "$ENGINE_MIN_INTERVAL" ]; then
            continue
        fi

        # 并发度门禁: 简单串行时直接执行;并发模式用任务计数
        if [ "$ENGINE_CONCURRENCY" -le 1 ]; then
            log "节点 ${n} 进入会话 (间隔 ${AGE}s >= ${ENGINE_MIN_INTERVAL}s)"
            run_session "$n" "$region"
        else
            if [ "$RUNNING" -lt "$ENGINE_CONCURRENCY" ]; then
                log "节点 ${n} 进入会话 (并发槽 ${RUNNING})"
                run_session "$n" "$region" &
                RUNNING=$((RUNNING + 1))
            fi
        fi
    done <<< "$NODES"

    # 并发模式: 等本轮任务全部收尾
    if [ "$ENGINE_CONCURRENCY" -gt 1 ]; then
        wait
    fi
done
