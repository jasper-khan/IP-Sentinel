#!/bin/bash
# ==========================================================
# 脚本名称: gen_manifest.sh (维护工具)
# 核心功能: 生成 MANIFEST.sha256 —— 仓库对外分发文件的哈希锁定清单
# 用法: 在仓库根目录执行 bash scripts/gen_manifest.sh，
#       确认 diff 后随发布一起 commit。
# V3 修复: OTA / 安装链下载的 root 执行内容必须有锁定哈希可验
# ==========================================================
cd "$(dirname "$0")/.." || exit 1

MANIFEST="MANIFEST.sha256"

# OTA 与安装链会以 root 执行的文件，全部纳入锁定范围
PATHS=(
    "core/install.sh"
    "master/install_master.sh"
    "install/build_master.sh"
    "install/env_setup.sh"
    "install/master_setup.sh"
    "install/engine_setup.sh"
    "core/agent_daemon.sh"
    "core/updater.sh"
    "core/mod_quality.sh"
    "core/tg_report.sh"
    "core/uninstall.sh"
    "master/tg_master.sh"
    "master/uninstall_master.sh"
    "master/engine/camoufox_session.py"
    "master/engine/tunnel_manager.sh"
    "master/engine/scheduler.sh"
    "data/probe/ip.sh"
    "version.txt"
)

: > "$MANIFEST"
for f in "${PATHS[@]}"; do
    if [ -f "$f" ]; then
        # -t 强制文本模式: sha256sum 在部分平台 (Git-Bash/Windows) 对文本文件
        # 输出 '*' 二进制标记,导致 Linux 侧 awk $2 == "path" 匹配失败;
        # 统一剥除星号保证清单跨平台一致
        sha256sum "$f" | sed 's/^\([0-9a-f]\{64\}\) \*/\1  /' >> "$MANIFEST"
    else
        echo "WARN: $f missing, skipped" >&2
    fi
done

echo "✅ $MANIFEST regenerated ($(wc -l < "$MANIFEST") entries)"
echo "⚠️  发布流程: bump version.txt → 运行本脚本 → 一起 commit & tag"
