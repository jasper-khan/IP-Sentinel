#!/bin/bash
# ==========================================================
# 脚本名称: gen_manifest.sh (维护工具)
# 核心功能: 生成 MANIFEST.sha256 —— 仓库对外分发文件的哈希锁定清单
# 用法: 在仓库根目录执行 bash scripts/gen_manifest.sh，
#       确认 diff 后随发布一起 commit。
# V3 修复: OTA / 安装链下载的 root 执行内容必须有锁定哈希可验
# 关键: 哈希对 git 入库 blob (LF) 计算 —— Linux 下载方拿到的是
#       raw.githubusercontent 的 blob 内容。对工作区文件计算会被
#       Windows CRLF 污染 (v5.1.0/v5.1.1 两次事故根因)。
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
    # 必须已提交 (blob 存在于 HEAD),工作区未提交的改动不进清单
    if git cat-file -e "HEAD:$f" 2>/dev/null; then
        # 对 git blob 内容计算 SHA-256 (与 raw.githubusercontent 分发字节一致)
        blob_sha=$(git show "HEAD:$f" | sha256sum | awk '{print $1}')
        printf '%s  %s\n' "$blob_sha" "$f" >> "$MANIFEST"
    else
        echo "WARN: $f 未提交 (不在 HEAD),跳过 —— 请先 commit 再生成清单" >&2
    fi
done

echo "✅ $MANIFEST regenerated ($(wc -l < "$MANIFEST") entries, 对 git blob 哈希)"
echo "⚠️  发布流程: bump version.txt → commit → 运行本脚本 → commit 清单 → tag"
echo "    (清单必须最后生成: 它锁定的是已提交的 blob)"
