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
#   - 版本双锁: pip 包 + 浏览器构建。时区伪装由 Camoufox 二进制层
#     实现(非 JS 注入),上游行为变更会静默改变养护效果,故装机后校验
#     构建号,不符则告警。
#     已知良好组合 (2026-09-10 002 生产实测):
#       camoufox==0.5.6  +  浏览器 152.0.4-beta.30
#     注: CAMOUFOX_HOME 环境变量在 0.5.x 已移除,数据目录固定为
#     platformdirs.user_cache_dir("camoufox") (Linux: ~/.cache/camoufox)
# ==========================================================

CAMOUFOX_PIN="0.5.6"
CAMOUFOX_BROWSER_EXPECTED="152.0.4-beta.30"

do_engine_setup() {
    echo -e "\n[5/5] 正在部署浏览器养护引擎 (Camoufox) ..."

    # [配置持久化] ENGINE_CONCURRENCY/ENGINE_MIN_INTERVAL 以 master.conf 为准:
    # 先 source 已固化的值, 下方 `${VAR:-默认}` 才能取到 (否则 OTA 重写
    # systemd 单元时每次都会把调好的间隔/并发重置回默认 5400/2)
    [ -f "${MASTER_DIR}/master.conf" ] && . "${MASTER_DIR}/master.conf"

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
        "camoufox[geoip]==${CAMOUFOX_PIN}" >/dev/null 2>&1 || {
        echo -e "\033[33m⚠️ camoufox pip 安装失败，引擎未部署 (网络?)。可稍后重跑安装修复。\033[0m"
        return 0
    }

    if ! "${MASTER_DIR}/venv/bin/python3" -c "import camoufox" >/dev/null 2>&1; then
        echo -e "\033[33m⚠️ camoufox 模块不可用，引擎未部署。\033[0m"
        return 0
    fi

    # 浏览器本体 (缺失时拉取;已存在跳过)
    # 注: camoufox fetch 在装了 geoip extra 时会顺带下载 GeoIP 数据库 (mmdb)
    #     探测用 installed_verstr() 而非目录存在性 (CAMOUFOX_HOME 已废弃, 见头注)
    BROWSER_VER=$("${MASTER_DIR}/venv/bin/python3" -c \
        "from camoufox.pkgman import installed_verstr; print(installed_verstr())" 2>/dev/null || true)
    if [ -z "$BROWSER_VER" ]; then
        echo "🦊 正在拉取 Camoufox 浏览器本体 (~150MB, 首次较慢)..."
        "${MASTER_DIR}/venv/bin/python3" -m \
            camoufox fetch >/dev/null 2>&1 || {
            echo -e "\033[33m⚠️ 浏览器本体拉取失败，可稍后手动执行: ${MASTER_DIR}/venv/bin/python3 -m camoufox fetch\033[0m"
        }
        BROWSER_VER=$("${MASTER_DIR}/venv/bin/python3" -c \
            "from camoufox.pkgman import installed_verstr; print(installed_verstr())" 2>/dev/null || true)
    fi

    # [版本锁定] 构建号须等于已知良好版本; 不符告警不阻断 (会话多半仍可跑)
    if [ -z "$BROWSER_VER" ]; then
        echo -e "\033[31m❌ 浏览器本体不可用 (installed_verstr 无输出)，引擎无法养护。\033[0m"
    elif [ "$BROWSER_VER" != "${CAMOUFOX_BROWSER_EXPECTED}" ]; then
        echo -e "\033[33m⚠️ 浏览器构建与锁定版本不符: 实际 ${BROWSER_VER}, 锁定 ${CAMOUFOX_BROWSER_EXPECTED}\033[0m"
        echo -e "\033[33m   时区伪装由二进制层实现, 构建变更可能改变养护效果, 请跑一轮养护自检确认后再放行。\033[0m"
    else
        echo "✅ Camoufox 版本已锁定: pip ${CAMOUFOX_PIN} / 浏览器 ${BROWSER_VER}"
    fi

    # ---------- 1.5 GeoIP 数据库 (geoip=True 运行时必需) ----------
    # 地理跟随出口 IP 需要 MaxMind mmdb。camoufox fetch 已尝试下载,此处显式
    # 校验:不可用则单独补拉。缺库会导致会话 UnknownIPLocation 崩溃,必须堵死。
    if ! "${MASTER_DIR}/venv/bin/python3" -c \
        "from camoufox.geolocation import geoip_allowed, get_mmdb_path; geoip_allowed(); import os; assert os.path.exists(get_mmdb_path('ipv4'))" >/dev/null 2>&1; then
        echo "🌍 正在补拉 GeoIP 数据库 (地理跟随出口 IP 所需)..."
        "${MASTER_DIR}/venv/bin/python3" -c \
            "from camoufox.geolocation import download_mmdb; download_mmdb()" >/dev/null 2>&1 || {
            echo -e "\033[33m⚠️ GeoIP 数据库拉取失败。地理跟随将不可用 (会话仍可跑但无 geoip 地理)。\033[0m"
            echo -e "\033[33m   可稍后手动执行: ${MASTER_DIR}/venv/bin/python3 -c 'from camoufox.geolocation import download_mmdb; download_mmdb()'\033[0m"
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
    # [完整性门禁] 四个引擎文件属同一版产物, 按"整组"原子落位:
    #   全部下载 → 逐个对 MANIFEST 校验 → 全数通过才统一 mv 进 engine/。
    #   任一失败即熔断并清空暂存 —— 绝不落成"新调度器 + 旧浏览器引擎"的混版状态。
    #   (范式同下方时区表: 退出条件是"哈希对上了"而非"拿到了文件";
    #    这四个是 root 运行的引擎本体, 拉取失败/哈希不符/清单缺条目均熔断)
    mkdir -p "${MASTER_DIR}/engine" "${MASTER_DIR}/data" "${MASTER_DIR}/profiles" "${MASTER_DIR}/logs"
    ENG_FILES="camoufox_session.py tunnel_manager.sh scheduler.sh tg_digest.sh"
    ENG_STAGE=$(mktemp -d "${MASTER_DIR}/.engine_stage.XXXXXX")
    for f in $ENG_FILES; do
        ENG_EXPECTED=$(awk -v t="master/engine/${f}" '$2 == t {print $1}' "${SECURE_TMP}/MANIFEST.sha256" 2>/dev/null)
        ENG_OK=""
        for _i in 1 2 3 4 5; do
            if curl -fsSL --connect-timeout 10 "${REPO_RAW_URL}/master/engine/${f}?t=$(date +%s)" -o "${ENG_STAGE}/${f}" 2>/dev/null; then
                if [ -n "$ENG_EXPECTED" ] && [ "$(sha256sum "${ENG_STAGE}/${f}" | awk '{print $1}')" = "$ENG_EXPECTED" ]; then
                    ENG_OK="1"; break          # 哈希一致 = 重试的唯一退出条件
                fi
            fi
            sleep 2
        done
        if [ -z "$ENG_OK" ]; then
            for _c in $ENG_FILES; do rm -f "${ENG_STAGE}/${_c}"; done
            rmdir "$ENG_STAGE" 2>/dev/null
            echo -e "\033[31m❌ 供应链熔断：引擎文件 ${f} 拉取失败, 或哈希与 MANIFEST 不符 (含清单缺条目)。\033[0m"
            echo "🛡️ 防砖机制触发：已中止安装；engine/ 目录保持原样, 未被覆写。"
            exit 1
        fi
    done
    for f in $ENG_FILES; do
        mv -f "${ENG_STAGE}/${f}" "${MASTER_DIR}/engine/${f}"
        echo "✅ 引擎文件已校验落位: ${f}"
    done
    rmdir "$ENG_STAGE" 2>/dev/null
    chmod +x "${MASTER_DIR}/engine/tunnel_manager.sh" "${MASTER_DIR}/engine/scheduler.sh" "${MASTER_DIR}/engine/tg_digest.sh" 2>/dev/null

    # ---------- 4. 引擎数据 ----------
    # 时区表 (persona 用); 区域模板/关键词/坐标由注册报文携带 + 调度器按需拉取,
    # 不在装机时点拉取 (Master 先装、节点后注册,装机时 DB 为空)
    #
    # [完整性门禁] 下载 → 对 MANIFEST 校验 → 原子落位。三点:
    #   1. shell 级循环重试, 退出条件是"哈希对上了"而非"拿到了文件" — curl 的
    #      --retry 不重试 404, 而 raw.githubusercontent 的间歇 404 是瞬时故障
    #      (见 install_master.sh fetch_retry 注释: 实测 5 次内必过)
    #   2. 先落临时文件、校验通过才 mv: 直接 -o 目标文件时, 一次 404 会把已装好的
    #      表截断清空 (curl -f 失败仍会创建输出文件), 引擎随后静默回落 geoip 粗判
    #      (正是 v5.6.2 修的那个 bug, 只是换了触发途径)。原子替换杜绝之。
    #   3. 时区表缺位只降精度不致命 (回退 geoip 粗判), 故失败告警不熔断 —
    #      但绝不覆写旧文件, 陈旧的好表胜过没有表
    TZ_TMP=$(mktemp "${MASTER_DIR}/data/.timezones.XXXXXX")
    TZ_EXPECTED=$(awk '$2 == "data/timezones.json" {print $1}' "${SECURE_TMP}/MANIFEST.sha256" 2>/dev/null)
    TZ_OK=""
    for _i in 1 2 3 4 5; do
        if curl -fsSL --connect-timeout 10 "${REPO_RAW_URL}/data/timezones.json?t=$(date +%s)" -o "$TZ_TMP" 2>/dev/null; then
            if [ -z "$TZ_EXPECTED" ]; then
                TZ_OK="1"; break          # 清单无此条目 (版本错配) → 无从校验, 按全项目惯例放行
            elif [ "$(sha256sum "$TZ_TMP" | awk '{print $1}')" = "$TZ_EXPECTED" ]; then
                TZ_OK="1"; break          # 哈希一致 = 重试的唯一退出条件
            fi
        fi
        sleep 2
    done
    if [ -n "$TZ_OK" ]; then
        mv -f "$TZ_TMP" "${MASTER_DIR}/data/timezones.json"
        if [ -n "$TZ_EXPECTED" ]; then
            echo "✅ 时区表已校验落位 (哈希与 MANIFEST 一致)"
        else
            echo "✅ 时区表已落位 (清单无条目, 未校验)"
        fi
    else
        rm -f "$TZ_TMP"
        echo -e "\033[33m⚠️ 时区表拉取/校验失败 (5 次重试后仍不通过), 未覆写已有文件。\033[0m"
        echo -e "\033[33m   后果: 会话时区回落 geoip 粗判 (实测 LA 出口会判成 Chicago, 差 2h)。\033[0m"
        echo -e "\033[33m   修复: 重跑本安装, 或手动拉取 data/timezones.json 至 ${MASTER_DIR}/data/\033[0m"
    fi

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

        cat > /etc/systemd/system/ip-sentinel-digest.service << EOF
[Unit]
Description=IP-Sentinel Daily Nurture Digest
After=network-online.target ip-sentinel-master.service

[Service]
Type=oneshot
ExecStart=/bin/bash ${MASTER_DIR}/engine/tg_digest.sh
User=root
CPUSchedulingPolicy=idle
IOSchedulingClass=idle
EOF

        cat > /etc/systemd/system/ip-sentinel-digest.timer << EOF
[Unit]
Description=Timer for IP-Sentinel Daily Nurture Digest
[Timer]
OnCalendar=*-*-* 16:00:00 UTC
Persistent=true
Unit=ip-sentinel-digest.service
[Install]
WantedBy=timers.target
EOF

        systemctl daemon-reload
        systemctl enable --now ip-sentinel-tunnels.service >/dev/null 2>&1
        systemctl enable --now ip-sentinel-engine.service >/dev/null 2>&1
        systemctl enable --now ip-sentinel-digest.timer >/dev/null 2>&1
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
