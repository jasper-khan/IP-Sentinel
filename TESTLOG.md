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
- [x] Master 干净重装: 凭证正确/三服务 active/venv+camoufox+隧道密钥全就位
- [x] Agent 同机安装: config 13 字段齐(PSK 64hex/US-LA persona/MASTER_EGRESS_IP=127.0.0.1)/探针 vendor 落地/runner 不部署(引擎代管)
- [x] 修复 bug 4: scheduler active_sessions 多行崩溃 (pgrep -fc 空输出) → 已修+重部署
- [x] 发现环境冲突: cloudnium 旧机原版 Master 抢占同 token getUpdates (409) → 已停旧机服务
- [x] 注册入库: 13 字段全验(PSK 64hex/persona US-LA/双栈地址/ssh_port/tunnel_user);旧 Master 吞掉的首注册由人工转发补回
- [x] **指令链 E2E 全过**: PSK签名指令执行(Action Accepted)/错误PSK 401/重放401/TOFU锁定+不匹配检测/时间窗外401
- [x] **防火墙限源实测**: 公网 IP 被拦(限源生效),127.0.0.1 放行
- [~] Camoufox 会话 + 指纹持久化 (运行中)

### Agent 安装明细验证
- config: AGENT_VERSION=5.2.1, REGION=US-LA, AGENT_PORT=36357, NODE_ALIAS=L-test
- PSK: 64 hex present; SSH_PORT=22; TUNNEL_USER=sentinel-tunnel
- 服务: agent-daemon active; runner 不存在(✅ 引擎代管); probe vendor+sha 落地
- sentinel-tunnel 用户不存在(同机未贴公钥,正确)
