#!/bin/bash
# ==========================================================
# 模块名称: build_master.sh (v4.3.0 Orchestrator)
# 核心功能: Master 安装业务总指挥，按原版时序复用组件
# ==========================================================

# 传递中断引信
trap 'exit 1' INT QUIT TERM

# Master 需要复用 env_setup、master_setup 和浏览器引擎安装
MODULES=(
    "env_setup.sh"
    "master_setup.sh"
    "engine_setup.sh"
)

for mod in "${MODULES[@]}"; do
    curl -fsSL --connect-timeout 10 --retry 3 "${REPO_RAW_URL}/install/${mod}?t=$(date +%s)" -o "${SECURE_TMP}/${mod}"
    if [ ! -s "${SECURE_TMP}/${mod}" ]; then
        echo -e "\033[31m❌ 致命错误：中枢依赖模块 [${mod}] 装载失败！\033[0m"
        exit 1
    fi

    # [V3 供应链门禁] 模块哈希须与 MANIFEST.sha256 一致
    if [ -s "${SECURE_TMP}/MANIFEST.sha256" ]; then
        MOD_EXPECTED=$(awk -v f="install/${mod}" '$2 == f {print $1}' "${SECURE_TMP}/MANIFEST.sha256")
        MOD_ACTUAL=$(sha256sum "${SECURE_TMP}/${mod}" | awk '{print $1}')
        if [ -z "$MOD_EXPECTED" ] || [ "$MOD_EXPECTED" != "$MOD_ACTUAL" ]; then
            echo -e "\033[31m❌ 供应链熔断：模块 [${mod}] 哈希与 MANIFEST 不符，拒绝执行。\033[0m"
            exit 1
        fi
    fi

    source "${SECURE_TMP}/${mod}"
done

# ==========================================================
# 核心业务原子流 (100% 忠实于原版 install_master.sh 执行时序)
# ==========================================================

# [复用模块: env_setup.sh]
do_master_env_precheck   # 预检 (复用了与 Agent 相同逻辑但修改了提示语，见下方)
do_fetch_master_version  # 抓取版本
do_master_handle_menu    # 拦截指令或展示交互菜单
do_install_deps          # [复用 Agent] 多分支依赖安装

# [专属模块: master_setup.sh]
do_master_clean_env      # 环境清理
do_master_config         # 令牌收集与 conf 生成
do_master_init_db        # SQLite 表结构固化
do_master_deploy_core    # 覆写内核、守护进程注入
do_engine_setup          # 浏览器引擎 (Camoufox) + 隧道密钥 + 调度守护
do_master_summary        # 态势汇报与回执

exit 0
