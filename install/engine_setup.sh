#!/bin/bash
# ==========================================================
# 模块名称: engine_setup.sh (浏览器引擎安装模块)
# 核心功能: Master 专属——Camoufox 浏览器引擎、隧道密钥、数据
#           (区域模板/关键词/时区表)、systemd 守护
# 设计:
#   - venv 隔离,不污染系统 python
#   - 隧道密钥 ed25519 私钥永不离开 Master,公钥打印给用户
#     在 Agent 安装时粘贴
#   - OTA 升级复用本模块: 已有密钥/venv 不动,只更新引擎文件
# ==========================================================

do_engine_setup() {
    echo -e "\n[5/5] 正在部署浏览器养护引擎 (Camoufox) ..."

    # ---------- 1. venv + Camoufox ----------
    if [ ! -x "${MASTER_DIR}/venv/bin/python3" ]; then
        echo "🐍 正在创建 Python 虚拟环境 (venv)..."
        python3 -m venv "${MASTER_DIR}/venv" || {
            echo -e "\033[31m❌ venv 创建失败 (缺 python3-venv?)，引擎未安装，Master 其余功能不受影响。\033[0m"
            return 0
        }
    fi

    echo "📦 正在安装/校验 Camoufox (首次较慢)..."
    "${MASTER_DIR}/venv/bin/pip" install --quiet --disable-pip-version-check \
        "camoufox[geoip]" >/dev/null 2>&1 || {
        echo -e "\033[33m⚠️ camoufox pip 安装失败，引擎未部署 (网络?)。可稍后重跑安装修复。\033[0m"
        return 0
    }

    if ! "${MASTER_DIR}/venv/bin/python3" -c "import camoufox" >/dev/null 2>&1; then
        echo -e "\033[33m⚠️ camoufox 模块不可用，引擎未部署。\033[0m"
        return 0
    fi

    # 浏览器本体 (缺失时拉取;已存在跳过)
    if ! ls "${MASTER_DIR}/.camoufox" >/dev/null 2>&1; then
        echo "🦊 正在拉取 Camoufox 浏览器本体 (~150MB, 首次较慢)..."
        CAMOUFOX_HOME="${MASTER_DIR}/.camoufox" "${MASTER_DIR}/venv/bin/python3" -m \
            camoufox fetch >/dev/null 2>&1 || {
            echo -e "\033[33m⚠️ 浏览器本体拉取失败，可稍后手动执行: ${MASTER_DIR}/venv/bin/python3 -m camoufox fetch\033[0m"
        }
    fi

    # ---------- 2. 隧道密钥 (仅首次生成; 升级不动) ----------
    if [ ! -f "${MASTER_DIR}/tunnel_key" ]; then
        echo -e "🔐 正在生成引擎专用隧道密钥 (ed25519)..."
        ssh-keygen -t ed25519 -N "" -C "ip-sentinel-engine" \
            -f "${MASTER_DIR}/tunnel_key" >/dev/null 2>&1
    fi
    chmod 600 "${MASTER_DIR}/tunnel_key"

    # ---------- 3. 引擎文件 ----------
    mkdir -p "${MASTER_DIR}/engine" "${MASTER_DIR}/data" "${MASTER_DIR}/profiles" "${MASTER_DIR}/logs"
    for f in camoufox_session.py tunnel_manager.sh scheduler.sh; do
        curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/master/engine/${f}?t=$(date +%s)" \
            -o "${MASTER_DIR}/engine/${f}" || {
            echo -e "\033[33m⚠️ 引擎文件 ${f} 拉取失败。\033[0m"
        }
    done
    chmod +x "${MASTER_DIR}/engine/tunnel_manager.sh" "${MASTER_DIR}/engine/scheduler.sh" 2>/dev/null

    # ---------- 4. 引擎数据 (区域模板/关键词/时区表) ----------
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/timezones.json?t=$(date +%s)" \
        -o "${MASTER_DIR}/data/timezones.json" 2>/dev/null || true

    # 区域模板与关键词: 仅拉取 DB 中已注册节点的区域 (按需)
    ENGINE_REGIONS=$(printf ".timeout 5000\nSELECT DISTINCT region FROM nodes WHERE region IS NOT NULL AND region != 'UNKNOWN';\n" | sqlite3 "${DB_FILE}" 2>/dev/null)
    for reg in $ENGINE_REGIONS; do
        [ -z "$reg" ] && continue
        mkdir -p "${MASTER_DIR}/data/regions/${reg}" "${MASTER_DIR}/data/keywords"
        # 该区域全部州/市模板 (tar 太重,用 GitHub API 列文件逐个拉;区域文件量小)
        curl -fsSL --connect-timeout 10 --retry 2 \
            "https://api.github.com/repos/jasper-khan/IP-Sentinel/contents/data/regions/${reg}?ref=main" 2>/dev/null \
            | grep -o '"path": "data/regions/[^"]*"' | cut -d'"' -f4 | while read -r rpath; do
            if echo "$rpath" | grep -q '\.json$'; then
                mkdir -p "${MASTER_DIR}/$(dirname "$rpath")"
                curl -fsSL --connect-timeout 10 --retry 2 "${REPO_RAW_URL}/${rpath}" \
                    -o "${MASTER_DIR}/${rpath}" 2>/dev/null || true
            fi
        done
        curl -fsSL --connect-timeout 10 --retry 2 "${REPO_RAW_URL}/data/keywords/kw_${reg}.txt?t=$(date +%s)" \
            -o "${MASTER_DIR}/data/keywords/kw_${reg}.txt" 2>/dev/null || true
    done

    # ---------- 5. systemd 守护 ----------
    if is_systemd; then
        cat > /etc/systemd/system/ip-sentinel-tunnels.service << EOF
[Unit]
Description=IP-Sentinel Engine SSH Tunnel Pool
After=network-online.target ip-sentinel-master.service

[Service]
Environment="MASTER_DIR=${MASTER_DIR}"
Environment="DB_FILE=${MASTER_DIR}/sentinel.db"
ExecStart=/bin/bash ${MASTER_DIR}/engine/tunnel_manager.sh
Restart=always
RestartSec=10
User=root

[Install]
WantedBy=multi-user.target
EOF

        cat > /etc/systemd/system/ip-sentinel-engine.service << EOF
[Unit]
Description=IP-Sentinel Camoufox Session Scheduler
After=network-online.target ip-sentinel-tunnels.service

[Service]
Environment="MASTER_DIR=${MASTER_DIR}"
Environment="DB_FILE=${MASTER_DIR}/sentinel.db"
Environment="ENGINE_CONCURRENCY=${ENGINE_CONCURRENCY:-1}"
Environment="ENGINE_MIN_INTERVAL=${ENGINE_MIN_INTERVAL:-5400}"
ExecStart=/bin/bash ${MASTER_DIR}/engine/scheduler.sh
Restart=always
RestartSec=30
User=root
Nice=10

[Install]
WantedBy=multi-user.target
EOF

        systemctl daemon-reload
        systemctl enable --now ip-sentinel-tunnels.service >/dev/null 2>&1
        systemctl enable --now ip-sentinel-engine.service >/dev/null 2>&1
        systemctl restart ip-sentinel-tunnels.service >/dev/null 2>&1
        systemctl restart ip-sentinel-engine.service >/dev/null 2>&1
    else
        pgrep -f tunnel_manager.sh >/dev/null || nohup bash "${MASTER_DIR}/engine/tunnel_manager.sh" >/dev/null 2>&1 &
        pgrep -f "engine/scheduler.sh" >/dev/null || nohup bash "${MASTER_DIR}/engine/scheduler.sh" >/dev/null 2>&1 &
    fi

    # ---------- 6. 汇报 ----------
    echo -e "\033[32m✅ 浏览器引擎部署完成 (隧道池 + 会话调度器已启动)。\033[0m"
    if [ -f "${MASTER_DIR}/tunnel_key.pub" ]; then
        echo ""
        echo -e "\033[36m═══════════════════════════════════════════════════════════════\033[0m"
        echo -e "\033[36m📋 隧道公钥 (在每台 Agent 安装时 [4.3/7] 步骤粘贴此公钥):\033[0m"
        echo ""
        cat "${MASTER_DIR}/tunnel_key.pub"
        echo ""
        echo -e "\033[36m═══════════════════════════════════════════════════════════════\033[0m"
    fi
}
