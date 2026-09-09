#!/bin/bash
# ==========================================================
# 脚本名称: tunnel_manager.sh (浏览器引擎 · SSH 隧道池管理)
# 核心功能: 依据 Master 数据库的节点登记,为每个节点维护一条
#           `ssh -D` SOCKS5 隧道 (仅转发,无 shell),供 Camoufox
#           会话借用对应节点出口。
# 设计:
#   - 每节点本地端口从 10801 递增分配,端口映射持久化记录
#   - 子进程 ssh 带 ExitOnForwardFailure + ServerAlive 保活,
#     退出后由主循环自动重拉
#   - 每 60s 轮询 DB: 新节点自动建隧道,移除节点自动下线
# ==========================================================

MASTER_DIR="${MASTER_DIR:-/opt/ip_sentinel_master}"
DB_FILE="${DB_FILE:-${MASTER_DIR}/sentinel.db}"
TUNNEL_KEY="${MASTER_DIR}/tunnel_key"
PORT_MAP_FILE="${MASTER_DIR}/.tunnel_ports"
LOG_FILE="${MASTER_DIR}/logs/engine.log"
TUNNEL_USER_DEFAULT="sentinel-tunnel"
BASE_PORT=10801

mkdir -p "${MASTER_DIR}/logs"

log() {
    echo "[$(date -u '+%Y-%m-%d %H:%M:%S UTC')] [Tunnel ] $*" >> "$LOG_FILE"
}

db_exec() {
    printf ".timeout 5000\n%s\n" "$1" | sqlite3 "$DB_FILE"
}

# [启动门禁] 无私钥即退出 (引擎安装器负责生成)
if [ ! -f "$TUNNEL_KEY" ]; then
    log "FATAL 隧道私钥缺失 ($TUNNEL_KEY)，退出"
    exit 1
fi
chmod 600 "$TUNNEL_KEY"

declare -A CHILD_PIDS      # node_name -> ssh pid
declare -A NODE_PORTS      # node_name -> local socks port

# 载入持久化端口映射,保证节点端口跨重启稳定
load_port_map() {
    [ -f "$PORT_MAP_FILE" ] || return
    while IFS='|' read -r n p; do
        [ -n "$n" ] && [ -n "$p" ] && NODE_PORTS["$n"]="$p"
    done < "$PORT_MAP_FILE"
}

save_port_map() {
    : > "$PORT_MAP_FILE"
    for n in "${!NODE_PORTS[@]}"; do
        echo "${n}|${NODE_PORTS[$n]}" >> "$PORT_MAP_FILE"
    done
    chmod 600 "$PORT_MAP_FILE"
}

# [全局结果变量] alloc_port 把端口写这里 (不用 echo+command substitution:
# 那会 fork 子 shell, NODE_PORTS 数组赋值随子 shell 蒸发, 父进程永不回放——
# 历史 bug: 6 节点连续 spawn 时 port map 每次被子 shell 的"空数组+1"覆盖,
# 最终文件只剩最后 spawn 的节点, 其余节点映射永久丢失 → 调度器判"隧道未就绪")
ALLOC_PORT=""

alloc_port() {
    local n="$1"
    if [ -n "${NODE_PORTS[$n]:-}" ]; then
        ALLOC_PORT="${NODE_PORTS[$n]}"
        return
    fi
    local p=$((BASE_PORT + RANDOM % 400))
    while grep -q "|${p}$" "$PORT_MAP_FILE" 2>/dev/null \
          || ss -tln 2>/dev/null | grep -q ":${p} "; do
        p=$((BASE_PORT + RANDOM % 400))
    done
    NODE_PORTS["$n"]="$p"
    save_port_map
    ALLOC_PORT="$p"
}

spawn_tunnel() {
    local n="$1" ip="$2" ssh_port="$3"
    local user="$4"
    local port
    alloc_port "$n"
    port="$ALLOC_PORT"

    # [双栈修复] DB 的 agent_ip 是多宿主串 "v4_[v6]" (多 IP 弹匣), ssh 只能连单一
    # 主机: 取第一段为主通讯地址 (注册时 SAFE_COMM_IP 排序, v4 优先)
    local connect_host="${ip%%_*}"

    # SSH 字面 IPv6 需要方括号
    if [[ "$connect_host" == *":"* && "$connect_host" != *"]"* ]]; then
        connect_host="[${connect_host}]"
    fi

    ssh -i "$TUNNEL_KEY" \
        -N -D "127.0.0.1:${port}" \
        -p "${ssh_port:-22}" \
        -o ExitOnForwardFailure=yes \
        -o StrictHostKeyChecking=accept-new \
        -o ServerAliveInterval=30 \
        -o ServerAliveCountMax=3 \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "${user}@${connect_host}" &
    CHILD_PIDS["$n"]=$!
    log "隧道上线: ${n} -> 127.0.0.1:${port} (${user}@${ip}:${ssh_port}) pid=${CHILD_PIDS[$n]}"
}

reap_tunnel() {
    local n="$1"
    if [ -n "${CHILD_PIDS[$n]:-}" ] && kill -0 "${CHILD_PIDS[$n]}" 2>/dev/null; then
        kill "${CHILD_PIDS[$n]}" 2>/dev/null
        wait "${CHILD_PIDS[$n]}" 2>/dev/null
    fi
    unset "CHILD_PIDS[$n]"
}

# 本机公网 IP 探测 (启动时一次;判定"同机节点"跳过其隧道)
LOCAL_EGRESS_IP=$(curl -4 -s -m 5 api.ip.sb/ip 2>/dev/null | tr -d '[:space:]')
log "本机出口 IP: ${LOCAL_EGRESS_IP:-未知}"

# 判定节点是否与 Master 同机:
#   - 注册地址含回环 (127.0.0.1 / ::1)
#   - 或注册首地址 == 本机出口公网 IP (双栈串如 1.2.3.4_[v6] 取第一段)
is_local_node() {
    local addr="$1"
    local first
    first=$(echo "$addr" | tr '_' ',' | cut -d',' -f1)
    [[ "$first" == 127.0.0.1 || "$first" == ::1 ]] && return 0
    [ -n "$LOCAL_EGRESS_IP" ] && [ "$first" == "$LOCAL_EGRESS_IP" ] && return 0
    return 1
}

load_port_map
log "========== 隧道池管理器启动 =========="

while true; do
    # 从 DB 拉取已注册且带 PSK 的节点 (无 PSK 的老节点无法指令下发,不建隧道)
    ACTIVE_NODES=$(db_exec "SELECT node_name, agent_ip, IFNULL(ssh_port,'22'), IFNULL(tunnel_user,'${TUNNEL_USER_DEFAULT}') FROM nodes WHERE psk IS NOT NULL AND psk != '';" 2>/dev/null)

    declare -A SEEN=()
    while IFS='|' read -r n ip ssh_port tun_user; do
        [ -z "$n" ] && continue
        SEEN["$n"]=1

        # 同机节点 (Master 与 Agent 同装): 无需隧道,引擎直连本机出口
        if is_local_node "$ip"; then
            continue
        fi

        # 不在线则 (重)拉起
        if [ -z "${CHILD_PIDS[$n]:-}" ] || ! kill -0 "${CHILD_PIDS[$n]}" 2>/dev/null; then
            spawn_tunnel "$n" "$ip" "$ssh_port" "$tun_user"
        fi
    done <<< "$ACTIVE_NODES"

    # DB 中已消失的节点: 下线其隧道 (端口映射保留,节点回归时复用)
    for n in "${!CHILD_PIDS[@]}"; do
        if [ -z "${SEEN[$n]:-}" ]; then
            log "隧道下线: ${n} (节点已注销)"
            reap_tunnel "$n"
        fi
    done
    unset SEEN

    sleep 60
done
