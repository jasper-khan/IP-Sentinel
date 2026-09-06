# E2E 测试日志 — cloudnium002 (2026-09-06)

## 阶段 1: 静态/回归 ✅ 全过

| # | 测试项 | 结果 |
|---|--------|------|
| R1 | 全仓库 bash -n (18 文件) | ✅ |
| R2 | Python AST (session.py + scripts) | ✅ |
| R3 | MANIFEST.sha256 全量校验 | ✅ 0 失配 |
| R4 | V1 回退源(IP.Check.Place)清除 | ✅ |
| R5 | V2 chat_id作密钥残留 | ✅ 无 |
| R6 | V4 降级签名路径 | ✅ 已移除 |
| R7 | V5 /tmp 可预测路径 | ✅ 无残留 |

## 阶段 2: 单元/集成 ✅ 全过 (7/7)

webhook.py 隔离实验台 (fcntl shim + 测试 config):
- U1 PSK 加载 (64 hex) ✅
- U2 HMAC 签名计算 ✅
- U3 401 同文 (uniform, 无预言机) ✅
- U4 限速: 5 失败→封禁, 其他 IP 不受累 ✅
- U5 死路由移除 + 6 活路由在位 ✅
- U6 并发上限 BoundedSemaphore(24) ✅
- U7 PSK 缺失/畸形拒听 exit(1) ✅

## 阶段 3: 发现并修复的 bug (3 个,已发版)

| Bug | 根因 | 修复 | 版本 |
|-----|------|------|------|
| manifest 星号 `*path` | Windows/Git-Bash sha256sum 二进制标记,awk 精确匹配失败 | 生成器 sed 剥星号 | v5.1.1 |
| manifest 哈希 CRLF 污染 | 对工作区文件计算,raw 分发的是 LF blob | git show HEAD: blob 哈希 | v5.2.0 |
| venv 静默失败 | Debian12 无 python3-venv,engine 降级不装 | 依赖列表补齐 | v5.2.1 |

发布流程固化: bump version → commit → gen_manifest → commit 清单 → tag

## 测试方法学教训

- tmux+tee 跑安装器假死 (wait_woken, 无子进程) → **printf 管道喂 stdin + nohup 才可靠**
- 二次安装会走"平滑升级"分支 source 旧 conf → 测试必须先抹干净 /opt/ip_sentinel_master
- termark heredoc 首行 BOM → 本地写脚本文件再 upload
- raw.githubusercontent CDN 缓存 version.txt (显示 v5.1.1) 无碍: 组件按 main 拉且过哈希门禁

## 阶段 4: E2E 安装

- [x] MANIFEST 供应链门禁 (GATE-PASS) + 篡改检出 (TAMPER-DETECT PASS)
- [x] Master 首装完成 (引擎 venv/camoufox/tunnel_key/三服务全部就位)
- [~] Master 凭证二次重装 (第一次 direct_test 残值污染 TG_TOKEN, 已抹净重装中)
- [ ] Agent 同机安装
- [ ] 注册入库 (13 字段含 PSK/persona)
- [ ] PSK 指令链 + TOFU
- [ ] Camoufox 会话 + 指纹持久化
- [ ] 区域自检落盘
- [ ] 升级 / 卸载
