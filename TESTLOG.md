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

## 测试中修复的 bug 累计 (6 个)

| # | Bug | 根因 | 版本 |
|---|-----|------|------|
| 1 | manifest 星号 | Git-Bash sha256sum 标记 | v5.1.1 |
| 2 | manifest CRLF | 工作区哈希 ≠ git blob | v5.2.0 |
| 3 | venv 缺失 | Debian 无 python3-venv | v5.2.1 |
| 4 | scheduler 崩溃 | pgrep -fc 空输出双行 | v5.2.x hot |
| 5 | 会话 FATAL: unexpected 'timezone' | Camoufox 构造无此参;须并入 config | v5.3.0 |
| 6 | 同机节点误建隧道 | 双栈注册串非 127.0.0.1 字面量 | v5.3.0 |

另修: geolocation 元组→dict;locale 补 region 修 LeakWarning

## 阶段 4: E2E 安装

- [x] MANIFEST 供应链门禁 (GATE-PASS) + 篡改检出 (TAMPER-DETECT PASS)
- [x] Master 干净重装: 凭证正确/三服务 active/venv+camoufox+隧道密钥全就位
- [x] Agent 同机安装: config 13 字段齐(PSK 64hex/US-LA persona/MASTER_EGRESS_IP=127.0.0.1)/探针 vendor 落地/runner 不部署(引擎代管)
- [x] 修复 bug 4: scheduler active_sessions 多行崩溃 (pgrep -fc 空输出) → 已修+重部署
- [x] 发现环境冲突: cloudnium 旧机原版 Master 抢占同 token getUpdates (409) → 已停旧机服务
- [x] 注册入库: 13 字段全验(PSK 64hex/persona US-LA/双栈地址/ssh_port/tunnel_user);旧 Master 吞掉的首注册由人工转发补回
- [x] **指令链 E2E 全过**: PSK签名指令执行(Action Accepted)/错误PSK 401/重放401/TOFU锁定+不匹配检测/时间窗外401
- [x] **防火墙限源实测**: 公网 IP 被拦(限源生效),127.0.0.1 放行
- [x] **Camoufox 会话完整闭环** (修复后): 指纹生成持久化→google.com→搜索"iphone ultra"→点击结果阅读→News→区域自检→profile 持久化; rc=0, gracefully close
- [x] **卸载验收全过**: 服务/目录/UFW规则(含限源)/tunnel用户 零残留
- [x] 修复 bug 7: engine_setup 补浏览器系统依赖 (Debian12 无 libgtk-3 → XPCOMGlueLoad 失败)
- [x] 修复 bug 8: 区域自检判定纳入 jump 落地域主信号 (002 实测 jump=com.hk 被误判 OK);7 用例单测全过
- [~] 指纹复用双会话验证 (运行中)

## 观察项 (原误报为"轻送中",已更正)

浏览器会话一次观察到 jump=www.google.com.hk,但与三个独立信号矛盾:
curl 直连不跳转 / YouTube GL+contentRegion=US / ipinfo geo=US-LA。
判定: 单次孤立样本,证据不足,非送中。调度器后续会话将持续采样,
若 jump=com.hk 复现则说明 Google 对该 IP 有 HK 倾向(值得养护),
不复现则为噪声。→ 自检判定的单信号矛盾场景应降级为"观察"待数据。

### Agent 安装明细验证
- config: AGENT_VERSION=5.2.1, REGION=US-LA, AGENT_PORT=36357, NODE_ALIAS=L-test
- PSK: 64 hex present; SSH_PORT=22; TUNNEL_USER=sentinel-tunnel
- 服务: agent-daemon active; runner 不存在(✅ 引擎代管); probe vendor+sha 落地
- sentinel-tunnel 用户不存在(同机未贴公钥,正确)
