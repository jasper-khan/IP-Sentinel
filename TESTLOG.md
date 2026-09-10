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
- [x] **指纹复用双会话验证 PASS**: 两次完整会话 fingerprint+seeds 哈希完全一致 (一个 IP = 一套固定设备身份)
- [x] **最终验收 11/11**: 三服务+agent-daemon active/runner 不存在/DB PSK/指纹三件套/.region/探针 vendor/UFW 限源(31043 ALLOW 127.0.0.1)
- [x] 区域自检判定升级为证据分级 (WATCH 观察级),13 用例单测全过

## 测试结论: 全部通过

v5.3.2-fork 在 cloudnium002 完成 功能/回归/验收/端到端 四层测试。
测试过程抓出并修复 9 个 bug (含发布流程 2、依赖 2、运行时 4、判定 1),
1 次误报更正 (002 送中 → 实为单样本噪声)。系统现作为测试中枢持续运行。

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
## 纯净重装测试 (2026-09-07 晨)

### 流程
根除(官方卸载器x2 + camoufox 状态清理,零残留) -> 纯净首装 Master -> Agent -> 注册入库 -> 调度器自动会话

### 结果
- 根除验证: 目录/服务/进程/UFW/camoufox 缓存 全部零残留
- Master 纯净首装: v5.3.2 -> v5.3.3, 三服务 active, venv+浏览器 fetch+密钥齐
- Agent 纯净首装: v5.3.3, PSK/persona/限源/探针 vendor/无 runner
- 注册: 用户转发 -> 入库 13 字段 (token 修复后自动从队列捞回,无需二次转发)
- 调度器自动首轮会话: 指纹持久化+完整 persona+动作流

### 新发现 bug (10)
- 安装器 stdin 间歇性错位 (管道喂答案时 TG_TOKEN 被截为 "1"):
  同答案序列两次错一次对,间歇性。仅影响自动化管道安装,真实交互式
  用户不受影响 (TTY 逐行 read 无错位机会)。待根因定位。
- Master 卸载需双确认 (菜单 2 + y),自动化喂答案需 2+y 两行

### 修复
- v5.3.3: 引导器 CDN 间歇 404 -> fetch_retry shell 循环 (curl --retry 不重试 404)
## 功能恢复 + 手动触发验证 (2026-09-07)

- v5.4.0: TG 面板恢复 Google 纠偏/信用净化入口 (浏览器引擎版):
  界面层沿用上游 (按钮/回调/布局), 执行层重写为本地触发文件队列 ->
  调度器 45-90s 消费 -> focus=google/trust/all 会话变体
- 手动触发 E2E 闭环 (用户点按钮 -> 日志验证):
  focus=google 会话完整跑通: 双轮搜索+点击阅读+News+Maps坐标驻留+区域自检
- engine_enabled 调度开关 (节点级暂停/恢复) 上线
- **jump=google.com.hk 连续两次复现** (浏览器会话), curl 直连不跳 --
  002 IP 在 Google 真人浏览器判定下有 HK 倾向, WATCH 持续追踪

---

# Safe OTA 加固测试 (2026-09-07, 本地, 未发版)

## 背景
对照 safe OTA 设计 (tag 锚定 + MANIFEST 验签 + 确认弹窗 + 逐台回报) 审计现有 OTA 链路,
确认 v4.4.0 V3/V5 修复后 Agent 侧验签已在,补齐三缺口。

## 改动 (本地未提交)
1. master 自升级: 补 MANIFEST 验签 (此前仅 bash -n) + 版本守卫 + tag 锚定
2. Agent OTA: 版本守卫 (已是最新→TG 回执跳过) + tag 锚定 (tag=v${VER}-fork)
3. 全舰队确认弹窗: 展示目标版本

## 验证 (全过)
- bash -n: tg_master.sh / agent_daemon.sh ✅
- 内嵌 python AST 解析 (路由 8 含新 f-string) ✅
- OTA f-string 按**文件真实 AST** 求值渲染 → bash -n ✅, printf 转义确认正确
- version_lt 功能测试 5 例 (含 5.5.9<5.5.10 语义化比较) ✅
- tag_raw_url: 抓出并修复 sed 拼接 bug (改 bash 参数展开), 现网 v5.5.0-fork tag raw URL 实测可达 ✅

## 边界行为
- version.txt 不可达 → 中止 (Agent 静默写 log / Master TG 告警)
- tag 未发布 (bump 未打 tag) → MANIFEST 拉取失败 → 熔断告警
- 本地版本 ≥ 远端 → 跳过并回执 (Agent TG 通知 / Master TG 通知)
- 验签失败 → 熔断告警, 不执行

---

# v5.6.2 - v5.6.6 发版测试 (2026-09-08, 002)

## v5.6.2 时区修复
- 探针实测(002, 真实页面非about:blank): 主线程恒UTC(152 build主文档realm bug), Worker吃config(PR#563实锤), add_init_script吃主线程 → 双realm互补方案
- E2E: 主线程+Worker均America/Los_Angeles(off 420 PDT); 真实会话 tz对齐+rc=0

## v5.6.3/5.6.4 每日简报双维度 + IP净化修复
- **净化bug发现**: 白名单static_urls在curl→浏览器迁移时投递漏接, 部署以来净化从未执行
- 修后E2E: 会话恢复白名单深访(walmart/dallasnews/foxnews), wl_US由调度器全新装机自动拉取
- 简报TG ok:true, 双维度真实数据

## v5.6.5 TOFU PSK挑战根治
- 受控失配E2E: 假指纹→/challenge PSK_ACK→自动重锁真实指纹, 零人工
- 两侧摘要算法一致性验证 (sha256(psk|node)[:16] == bash版)

## v5.6.6 三核+判定历史
- 9场景裁决单测全过 (含酷鸭HK目标判US=DRIFT, 孤立中文信号=WATCH, 无佐证YT-CN=定罪)
- E2E: 三核全通(Jump/Prem/Music=US), verdicts.jsonl落盘, 日报国家码格式, rc=0
- MUSIC探针在music.youtube.com提取contentRegion成功

## 附带发现
- 002混用资源竞争: UAV下载流水线与浏览器会话撞车时2G内存swap抖动(60MB/s), 会话拖慢至20min; UAV删除后基线356M, 可用1623M
- termark高频SSH连接风暴(已知): 低频轮询+单查模式规避

## v5.6.21 INIT_TZ_JS 失效确认与删除 (2026-09-10, 002 生产实测)

- **隔离三组对照** (独立临时 profile, 不走代理, 不写生产状态; page.html 页内嵌脚本读自身环境 = 无争议主世界, 注入脚本带 `window.__TZ_PATCH_MARKER__` 标记):
  - A 生产配置 (config tz + 注入): marker ABSENT, Intl=America/Los_Angeles, gto=420
  - B config tz 不注入: 逐项与 A 相同 → 注入加不加网页看到的一模一样
  - C 只注入不设 config tz: Intl=America/Chicago (geoip 粗判) 而非目标 LA → 注入单独存在时不生效
  - 三组 marker 全部 ABSENT → 脚本从未在页面执行 (Camoufox 隔离副本, upstream issue #48 同象)
- **根因**: Camoufox stealth 设计 — Playwright 全部 JS (含 add_init_script) 跑在 Juggler 隔离副本, 真实页面不受影响; 进主世界需 main_world_eval=True + mw: 前缀, 引擎未开
- **失效为何从未暴露**: add_init_script 调用永远成功返回 (except 永空) + 原生伪装输出与补丁目标一致 (同为 LA) → E2E 测"主线程时区 ✅"掩盖了注入失效
- **v5.6.2 结论部分修正**: "152 build 主文档恒 UTC" 不再成立 — 当前 camoufox 0.5.6 上 config['timezone'] 主文档与 Worker 两 realm 均生效 (B 组证实); 0.5.6 装机未 pin 版本 (已知风险, 待办)
- 删除后验证: py_compile 通过; INIT_TZ_JS/add_init_script/GeoSpoof/stripConstruct 全仓库零残留; 时区链 (resolve_timezone→config['timezone']→二进制层) 一行未动
- 生产影响: 零 (改动仅在仓库, /opt 副本经 OTA 生效); 测试期间六节点 .last 计时器未变, engine.log 无幽灵会话, profiles 无残留
- 遗留口子记录: document.lastModified / XSLT 时间偏移仍为服务器真值 (主世界执行代价评估后暂不修)

## v5.6.22 Camoufox 版本双锁 + timezones.json 下载门禁 (2026-09-10, 002 生产实测)

### 版本锁定
- 记录已知良好组合: pip camoufox==0.5.6 + 浏览器 152.0.4-beta.30 (PyPI 当前最新即 0.5.6)
- 生产实测探测语句: `installed_verstr()` → [152.0.4-beta.30]，与锁定值一致 → 走绿字确认分支
- `pip install --dry-run camoufox[geoip]==0.5.6` → 依赖全部 already satisfied (pin 有效且幂等)
- 关键前提: do_engine_setup 每次 Master OTA 都会执行 (TG 点 OTA → install_master.sh → build_master.sh → do_engine_setup)，非仅全新装机

### 发现并修复的既有缺陷
- **CAMOUFOX_HOME 在 camoufox 0.5.x 已被移除** (全包 grep 零命中)，数据目录硬编码为 user_cache_dir("camoufox") → `~/.cache/camoufox`
- 连带: `if ! ls "${MASTER_DIR}/.camoufox"` 判断恒为真，浏览器已装也会重走拉取
- 连带: GeoIP 校验/补拉两段的 CAMOUFOX_HOME 前缀均失效 (不生效但因路径恰为默认值而"碰巧能用")

### timezones.json 下载门禁 (沙箱四用例，抽出待发布代码段实跑)
| 用例 | 场景 | 结果 |
|------|------|------|
| 1 | 清单哈希正确 | ✅ 0.4s 校验通过并原子落位，旧表被替换 |
| 2 | 清单哈希错误 | ✅ 11.2s (5次重试+退避) 后告警，**旧表未被覆写**，无临时文件残留 |
| 3 | 清单无此条目 | ✅ 放行并注明"未校验" |
| 4 | 全新装机+哈希错误 | ✅ 告警，目标目录干净无残渣 |

- 修复的两个真实缺陷: (a) `curl --retry 3` 不重试 404 (curl 视 404 为永久错误)，而 raw.githubusercontent 间歇 404 是瞬时故障 — 项目内 `install_master.sh` 的 fetch_retry 注释已记载该现象; (b) `-o 目标文件` 就地覆盖，一次 404 即截断已装好的表 → 引擎静默回落 geoip 粗判 (v5.6.2 修的那个 bug 的另一种触发途径)

### 遗留观察 (未处理)
- Master OTA 的 tag 锚定只覆盖最外层 `install_master.sh`; 它内部 `REPO_RAW_URL` 硬编码为 `main`，故 build_master.sh/模块/MANIFEST 实际都从 main 拉取。发布时 tag==main 故无实际影响，但"tag 锚定"名义上不完整

### 锁定值的来源 (为什么是 0.5.6 / 152.0.4-beta.30)
- **取值原则: 锁的不是"最新"或"更稳"的版本, 而是"当时生产正在跑、且已验证有效"的那一个** —— 锁定的目的是阻止将来自动跳版, 不是升级或降级。故 OTA/重装时 `pip install ==0.5.6` 全程幂等 (dry-run 实测: 依赖全部 already satisfied)
- `camoufox==0.5.6` (pip 包): 2026-09-10 002 实测 `pip show camoufox` → Version 0.5.6 / `pip freeze` → camoufox==0.5.6。同时恰为 PyPI 当时最新版 (2026-09-06 发布; 上一版 0.5.5 为 08-18, 0.5.4 为 07-16), 即"当前最新"与"已验证"重合, 无需另行取舍
- `152.0.4-beta.30` (浏览器本体): 由 `camoufox fetch` 拉取的定制 Firefox 构建, 取自 `/root/.cache/camoufox/config.json` 的 `active_version` —— 目录全名为 `152.0.4-beta.30-5720d45b` (带 commit 短哈希), 而 `pkgman.installed_verstr()` 返回不带哈希的 `152.0.4-beta.30`, 故锁定常量用后者以匹配校验语句。这就是 v5.6.2 笔记中反复提到的 "152 build"
- 两轴关系: pip 包版本决定默认拉取哪个浏览器构建, 构建本身可单独指定; 正常情况锁 pip 包即锁定默认组合
- 该组合"已知良好"的实测依据: `config['timezone']` 在主文档与 Worker 两 realm 均生效 (v5.6.21 三组对照 B 组证据), 六节点 tz 全部 by_coords 精确命中, 养护会话 rc=0
- 日志措辞提醒: 装机输出 `✅ Camoufox 版本已锁定: pip 0.5.6 / 浏览器 152.0.4-beta.30` 中的 "pip" 指安装工具, 0.5.6 是 camoufox 包版本, 非 pip 自身版本
