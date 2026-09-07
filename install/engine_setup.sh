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

    # ---------- 0. 浏览器系统依赖 (Debian 最小安装无 GTK,实测 XPCOMGlueLoad 失败) ----------
    if command -v apt-get >/dev/null 2>&1; then
        apt-get install -y --no-install-recommends libgtk-3-0 libx11-xcb1 libxcb-shm0 libxcomposite1 libxdamage1 libxrandr2 libasound2 >/dev/null 2>&1 || true
    elif command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
        $PKG_MGR install -y gtk3 alsa-lib >/dev/null 2>&1 || true
    elif command -v apk >/dev/null 2>&1; then
        apk add --no-cache gtk+3.0 >/dev/null 2>&1 || true
    fi

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
    # 注: camoufox fetch 在装了 geoip extra 时会顺带下载 GeoIP 数据库 (mmdb)
    if ! ls "${MASTER_DIR}/.camoufox" >/dev/null 2>&1; then
        echo "🦊 正在拉取 Camoufox 浏览器本体 (~150MB, 首次较慢)..."
        CAMOUFOX_HOME="${MASTER_DIR}/.camoufox" "${MASTER_DIR}/venv/bin/python3" -m \
            camoufox fetch >/dev/null 2>&1 || {
            echo -e "\033[33m⚠️ 浏览器本体拉取失败，可稍后手动执行: ${MASTER_DIR}/venv/bin/python3 -m camoufox fetch\033[0m"
        }
    fi

    # ---------- 1.5 GeoIP 数据库 (geoip=True 运行时必需) ----------
    # 地理跟随出口 IP 需要 MaxMind mmdb。camoufox fetch 已尝试下载,此处显式
    # 校验:不可用则单独补拉。缺库会导致会话 UnknownIPLocation 崩溃,必须堵死。
    if ! CAMOUFOX_HOME="${MASTER_DIR}/.camoufox" "${MASTER_DIR}/venv/bin/python3" -c \
        "from camoufox.geolocation import geoip_allowed, get_mmdb_path; geoip_allowed(); import os; assert os.path.exists(get_mmdb_path('ipv4'))" >/dev/null 2>&1; then
        echo "🌍 正在补拉 GeoIP 数据库 (地理跟随出口 IP 所需)..."
        CAMOUFOX_HOME="${MASTER_DIR}/.camoufox" "${MASTER_DIR}/venv/bin/python3" -c \
            "from camoufox.geolocation import download_mmdb; download_mmdb()" >/dev/null 2>&1 || {
            echo -e "\033[33m⚠️ GeoIP 数据库拉取失败。地理跟随将不可用 (会话仍可跑但无 geoip 地理)。\033[0m"
            echo -e "\033[33m   可稍后手动执行: CAMOUFOX_HOME=${MASTER_DIR}/.camoufox ${MASTER_DIR}/venv/bin/python3 -c 'from camoufox.geolocation import download_mmdb; download_mmdb()'\033[0m"
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

    # ---------- 4. 引擎数据 ----------
    # 时区表 (persona 用); 区域模板/关键词/坐标由注册报文携带 + 调度器按需拉取,
    # 不在装机时点拉取 (Master 先装、节点后注册,装机时 DB 为空)
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/data/timezones.json?t=$(date +%s)" \
        -o "${MASTER_DIR}/data/timezones.json" 2>/dev/null || true

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
# 并发会话数: 2C/2G 建议 2; 内存充裕可调高 (每会话约 500-700M)
Environment="ENGINE_CONCURRENCY=${ENGINE_CONCURRENCY:-2}"
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
