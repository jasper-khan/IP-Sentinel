# Changelog

## [v5.6.30-fork] - 2026-09-13

### 🐛 Fixes

- **Master 运行时词库与白名单刷新** — 非空文件 24 小时内复用；过期或缺失时下载到同目录临时文件，仅成功且非空才原子替换；失败或空响应保留旧数据并准确记录，curl 设置总超时。
- **区域数据同步** — 纳入 2026-09-13 自动同步的数据提交。

## [v5.6.30-agent] - 2026-09-13

### 🐛 Fixes

- **Agent OTA 失败告警与临时文件清理** — `version.txt`、`MANIFEST.sha256` 或安装脚本下载失败，以及完整性/语法校验失败时发送明确告警并中止升级；通过 `EXIT` trap 统一清理 OTA 临时文件。

## [v5.6.29-fork] - 2026-09-11

### 🐛 Fixes

- **Agent 日报重构（节点日报）** — 用户反馈"每个机器的每日简报也太乱"。压缩为紧凑卡片：
  - **版本分轨显示**：`⚙️ 中枢 v5.6.29 · 代理 v5.6.29 ✅与仓库一致`——原"当前运行版本: v5.6.11 (✅已是最新)"在中枢已升到 5.6.x 后极具误导（代理/中枢版本独立，但读者分不清）
  - **布局压缩**：节点身份 / 守护状态 / 版本三段合一、分隔线统一，去掉"每日简报"里两份状态段的重叠
  - **时间精简**：守护进程"自 Wed 2026-09-09 02:41:34"→"运行自 09-09 02:41"；巡检时间同步精到分
  - **去掉促销尾缀**：GitHub 求星 footer 删除
  - 附带 `TG_REPORT_DRYRUN=1` 预览模式（与 Master 简报 `DIGEST_DRYRUN` 对齐，仅打印不发送，便于验证）
- **Agent OTA tag 通道拆分（修复命名空间撞车）** — agent OTA 原按 `v{AGENT_VERSION}-fork` 取 tag，与 master 历史 tag 共享命名空间：v5.6.0~v5.6.28 全部已被历史 master 发布占用（实测 bump agent 到 5.6.12 即撞已存在的 `v5.6.12-fork`），任何 5.6.x agent 版本都无法发布。修复：agent 通道改为 `v{VER}-agent`（master 仍 `v{VER}-fork`）。本次以 `v5.6.29-fork` 单 tag 双通道桥接发布（MASTER 5.6.27→5.6.29 + AGENT 5.6.11→5.6.29）：旧 agent 经旧方案拉取该 tag 装上带新方案的 agent_daemon，此后两通道各自独立命名，永不相撞

## [v5.6.27-fork] - 2026-09-11

### 🐛 Fixes

- **每日简报重构 (消除数字矛盾与语义噪音)** — 用户反馈"太乱难看"。四处修复：
  - **次数与达成率同源**：会话数以"区域自检"行为准（每会话恰好一条），消除"24h 12 次但 ✅0🔴13"的 24h 窗口边界错位（原实现次数按"会话结束"行、达成率按"自检"行，两个独立计数）
  - **判定分级明细**：`(✅X 🟠Y 🟡Z 🔴W ⚪V)` 只列非零——DRIFT 不再被压成 🔴（原来一切非 OK 全算红，酷鸭 13 次 DRIFT 显示成全崩）
  - **报警只认送中**：DRIFT/WATCH/PROBE_FAIL 不再触发 ⚠️ 头条（酷鸭 DRIFT 是已接受的恒常态，不该每天报警）；头条仅 🔴 送中出现
  - **OK 节点压缩**：最近自检从"🟢 目标达成 (Jump:US | Prem:US | Music:US) · 域名 · 时间"压缩为"🟢 目标达成 · 时间"（三核全目标区无信息量），异常节点仍展开三核+落地域名

## [v5.6.26-fork] - 2026-09-11

### 🐛 Fixes

- **调度间隔/并发参数 OTA 持久化** — `engine_setup.sh` 写 systemd 单元时只用 `${ENGINE_MIN_INTERVAL:-5400}`/`${ENGINE_CONCURRENCY:-2}` 环境变量，不读 `master.conf`。调好的间隔（如本次 45min=2700）一旦 OTA 重写单元就被重置回默认，且 OTA 路径不重写 master.conf（只 append 缺失键）→ master.conf 是持久家。修复：`do_engine_setup()` 写单元前先 source `master.conf`（存在才 source），`master.conf` 成为间隔/并发的唯一持久来源。002 已按此把 `ENGINE_MIN_INTERVAL` 调为 2700（45 分钟）

## [v5.6.25-fork] - 2026-09-10

### 🐛 Fixes

- **干净观测者探针强制 IPv4 出口** — 本机节点探针直连（无隧道）时浏览器默认 Happy Eyeballs 优先 IPv6。002 实测：同一主机 IPv4 `192.255.172.110` 被 Google 判 US（jump 留 www.google.com），IPv6 `2607:9d00:...` 被判 HK（jump→google.com.hk）。养护浏览器因 `geoip=True` 自动携带 `network.dns.disableIPv6`（v5.5.0 既有防双栈泄漏 pref），探针因不带 geoip 而缺此 pref —— 新探针上线后本机节点首轮读出假 HK 信号（Jump:HK + Prem:US → WATCH）。修复：探针 Camoufox 显式补同一根 pref，探针出口统一 IPv4。002 实测带 pref 后本机节点三核全绿（jump=www.google.com / prem=US / music=US）

## [v5.6.24-fork] - 2026-09-10

### 🐛 Fixes

- **区域自检改"干净观测者"探针 (剥离养护身份)** — 原探针复用养护浏览器的持久 profile 与累积 cookie，测得的是"浏览器记住了目标区域"而非"Google 对这个 IP 的判定"（cookie 让 Google 凭偏好作答而非凭 IP）。这是上游 PR #82（剥离探测身份，干净 UA 裸问）原则在浏览器化后的回归：fork 把养护搬进浏览器时探针也随之搬进养护浏览器，三核全部被 cookie 污染。现改为：会话主体浏览器结束后，单独开一个非持久、无 `user_data_dir`、无指纹/geoip 注入的全新 Camoufox 实例，走同一条 SOCKS 隧道（出口仍是节点 IP）裸问三核。判定逻辑 `region_verdict`、`.region`/`.verdicts.jsonl` 落盘、TG 面板、日报等消费端零改动
- **consent 墙处理** — 干净请求（无同意记录）可能落在 `consent.google.com`，原逻辑会把它当漂移信号计（单信号 → WATCH 误报）；现按探测失效处理（无信号≠漂移），裁决由 YT 两核兜底，对齐上游"YT 主导、容忍 Jump 失败"的裁决本意

## [v5.6.23-fork] - 2026-09-10

### 🐛 Fixes

- **OTA 临时文件不再累积 (回收历史遗留)** — `tg_master.sh` 的 OTA 用 `mktemp` 在 `${MASTER_DIR}` 建 `ota_install.*.sh` + `ota_manifest.*`, 但只在**熔断分支** `rm`, 成功路径不回收 → 每升一版留一对 (各约 5KB)。002 实测: 09-09 00:06 至 09-10 08:56 已积五对。修复: 在创建新文件**之前**清一次历史遗留 —— 此刻目录里存在的必属历史轮次; Linux unlink 不影响已打开的 fd, 即便有 OTA 正在读亦安全
  - 匹配范围经沙箱验证: 只命中 `ota_install.*.sh` / `ota_manifest.*`; 同目录的 `sentinel.db`/`master.conf`/`tg_master.sh`/`engine.log` 及形近名 (`ota_install_notes.txt`/`ota_manifest_backup`) 均不受影响; 同名目录不被 `rm -f` 触及
  - 已在 002 手工清空既有积压的 10 个文件 (另清理 4 个 09-08 遗留的 Agent 装机沙箱 `/tmp/ips_install.*`)

## [v5.6.22-fork] - 2026-09-10

### 🔒 Hardening

- **Camoufox 版本双锁 (pip 包 + 浏览器构建)** — 时区伪装由 Camoufox 二进制层实现 (非 JS 注入), 上游行为变更会静默改变养护效果 (v5.6.2 观测的 "主文档恒 UTC" 在当前构建上已不成立), 而 `pip install "camoufox[geoip]"` 原先不锁版本, 任何重装都会拉到当时最新版。现锁定 `camoufox==0.5.6` + 构建号 `152.0.4-beta.30` (2026-09-10 002 生产实测已知良好组合), 装机后校验构建号, 不符则告警并提示跑一轮养护自检
- **`data/timezones.json` 纳入 MANIFEST 并加下载门禁** — 该文件原先不入清单, 且用 `curl --retry 3 || true` 拉取: (a) `--retry` 不重试 404 而 raw.githubusercontent 的间歇 404 是瞬时故障; (b) `-o 目标文件` 就地覆盖, 一次 404 会把已装好的表**截断清空**, 引擎随即静默回落 geoip 粗判 —— 正是 v5.6.2 修的那个 bug 换了个触发途径。改为: 下载至临时文件 → 对 MANIFEST 校验 → 通过才原子 `mv`, **重试的退出条件是"哈希对上了"而非"拿到了文件"** (5 次, 对齐 `install_master.sh` 的 fetch_retry 惯用法); 5 次仍不通过则告警且**绝不覆写旧文件** (陈旧的好表胜过没有表)
- `scripts/gen_manifest.sh` PATHS 增补 `data/timezones.json`

### 🐛 Fixes

- **修复浏览器本体"已存在即跳过"判断恒为真** — 原判断是 `if ! ls "${MASTER_DIR}/.camoufox"`, 但 `CAMOUFOX_HOME` 环境变量在 camoufox 0.5.x 已被上游彻底移除 (全包零命中), 数据目录固定为 `platformdirs.user_cache_dir("camoufox")` (Linux: `~/.cache/camoufox`), 该目录永不创建 → 判断恒真, 每次装机都重走一遍拉取。改用 `pkgman.installed_verstr()` 探测 (缺库抛异常 → 空输出)
- 清除 3 处失效的 `CAMOUFOX_HOME=` 前缀 (GeoIP 校验/补拉两段), 它们不生效却误导读者以为路径受控

## [v5.6.21-fork] - 2026-09-10

### 🗑️ Removal

- **删除 INIT_TZ_JS 整段死代码 (486 行) + add_init_script 注入块** — 002 生产实测 (camoufox 0.5.6) 证实: Camoufox 把 Playwright 全部 JS 执行隔离在页面之外 (官方 stealth 设计, upstream issue #48), `add_init_script` 只在隔离副本执行, **网页从未见过这段补丁**。三组对照实测: config tz+注入 vs config tz 不注入, 网页读值逐项相同; 只注入不设 config tz, 网页读到 geoip 粗判值 (America/Chicago) 而非目标时区 — 注入对网页零贡献。时区伪装实际由 `config['timezone']` (城市坐标查表, v5.6.2) + Camoufox 二进制层原生承担, 主文档与 Worker 两 realm 均生效, 删除零行为变化
  - 附带废弃 `except` 永空 (add_init_script 调用永远成功返回, 注入失效不可观测)
  - v5.6.14~v5.6.20 十五个 commit 打磨的补丁从未在生产生效, E2E "主线程时区 ✅" 实为原生伪装的输出, 掩盖了注入失效
  - 文件头/`load_persona` docstring 两处陈年注释同步更正 (时区=城市坐标查表手动注入; 经纬度/locale/WebRTC=geoip 跟随出口 IP)
  - 已知遗留口子 (Camoufox 原生不管, JS 层本该管但进不去): `document.lastModified` 与 XSLT 时间偏移仍为服务器真值; 修它需 `main_world_eval=True` 走主世界, 可检测性上升, 评估后暂不处理

## [v5.6.6-fork] - 2026-09-08

### ✨ Features

- **区域自检升级三核 (对齐上游三核雷达, 浏览器版)** — 探针从双核 (Jump+Prem) 扩为 **Jump + YouTube Premium GL + YouTube Music GL**;判定维持证据分级 (不采用上游"YT 权重容忍 Jump 漂移"):
  - 双中文区证据 → 🔴 送中;单中文信号+其他支持目标 → 🟡 WATCH (下轮复核);单 YT=CN 无佐证 → 🔴 (维持强信号定罪);同区双漂移 → 🟠 DRIFT;三核全失效 → ⚪ PROBE_FAIL (对齐上游探针失效告警)
  - 9 场景单元测试全过 (含酷鸭 HK 目标判 US 的 DRIFT 案例)
- **判定历史 + 「📈 判定历史」面板 (对齐上游 /trend)** — 每轮会话追加 `profiles/<node>.verdicts.jsonl`;节点控制台新增「📈 判定历史」按钮,渲染近 15 轮 (时间/判定/Jump/Prem/Music),可观察 WATCH 自愈与送中渐进趋势。上游原有 /trend (质量探测历史) 保留不动
- **日报自检行对齐上游国家码格式** — `🟢 目标达成 (Jump: US | Prem: US | Music: US)`,异常时附原始落地域名证据;判定中文化 (目标达成/观察/区域漂移/送中)

## [v5.6.5-fork] - 2026-09-08

### 🐛 Fixes

- **TOFU 升级顺序窗口根治 (自动自愈)** — Master `call_agent` 证书指纹失配不再直接报 MITM 中止,先经当前 TLS 连接发 PSK 签名的 `/challenge`;Agent 回显 `sha256(PSK|NODE_NAME)` 前 16 位摘要,摘要一致 = 节点持有 PSK = 合法证书轮换 (OTA 重铸),自动重锁新指纹并继续原指令;不符/无应答才维持 MITM 告警。堵死"Agent 先升/Master 后升"顺序窗口 (该时序下轮换注册落在旧 Master 被错过,之后 Agent 因版本守卫不再注册,指纹永久失配须手动清)。安全论证: 伪造挑战应答需持有 PSK;转发型 MITM 只能转述真 Agent 应答 (危害上限=流量可见性,指令仍需 PSK 签名无法伪造破坏),与合法轮换不可区分按设计放行
- Agent 侧新增 `/challenge` 路由 (必经 HMAC 中间件,401 同文防护维持)
- 002 实测 (受控失配): 假指纹 → PSK_ACK 挑战 → 自动重锁回真实指纹,零人工干预

## [v5.6.4-fork] - 2026-09-08

### 🐛 Fixes

- **修复 IP 信用净化一直未执行 (curl→浏览器迁移的数据投递漏接)** — 净化深访目标 `static_urls` 来自区域模板 `trust_module`,curl 时代模板随装机拉到 agent 本地;养护搬到 Master 引擎后,模板既没随注册报文送来、调度器也只拉了关键词 (没拉白名单),导致引擎 `static_urls=[]`、白名单深访被跳过——**部署以来只跑了 Google 区域纠偏,IP 信用净化从未执行**。修复: 新增按国家白名单 `data/whitelist/wl_<CC>.txt` (从区域模板 static_urls 聚合,全国性站点不分城市),调度器 `ensure_whitelist` 按需拉取 (完全仿 `ensure_keywords`),引擎 `load_whitelist` 读取。002 实测: 会话恢复白名单深访 (foxnews/visitbuffaloniagara 等),rc=0

### ✨ Features

- **每日养护简报增强为上游双维度结构** — 对齐上游"每日简报"的两大产品维度 (Camoufox 引擎驱动):
  - 🎯 **Google 区域纠偏**: 24h 养护会话数 · 区域自检达成率 (✅达成 / 🔴送中漂移) · 最新自检结论 (jump 落地域名 + 时间)
  - 🔰 **IP 信用净化**: 24h 白名单深访次数
  - 每节点独立卡片 (国旗 + 区域/城市 + 出口 IP + 时区),全局汇总纠偏/净化总数 + 异常告警,底部战报时间 + 引擎版本
  - `DIGEST_DRYRUN=1` 预览不发送

## [v5.6.3-fork] - 2026-09-08

### ✨ Features

- **每日养护简报 (Master 侧重建)** — 恢复上游"每日简报"能力,但重建在 Master 引擎侧: curl 退役后养护数据从 agent 本地搬到 Master 引擎,agent 侧日报只剩空壳 (代码曾注释"养护统计由 Master 引擎日志承载"却未实现)。新增 `master/engine/tg_digest.sh` + `ip-sentinel-digest.timer` (每日 16:00 UTC),聚合引擎养护活动按 chat_id 分组发 TG:
  - 逐节点: 别名/区域、IP、时区、24h 养护会话数 (成功数)、最新区域自检结论 (🟢OK/🟡WATCH/🟠DRIFT/🔴送中)
  - 全局: 节点总数、24h 养护总数、异常节点告警
  - 数据源: `engine.log` (会话/时间戳) + `profiles/*.region` (自检落盘) + DB (节点档案),纯读取零新依赖
- 引擎侧改动,Agent 不受影响 (仅 bump MASTER_VERSION)

## [v5.6.2-fork] - 2026-09-08

### ✨ Features

- **时区按节点城市对齐 (主线程 + Worker 双realm)** — 养护会话时区不再靠 geoip 的 IP 粗判 (实测把 LA 出口判成 America/Chicago,差 2h),改由节点城市坐标定 IANA 时区:
  - **坐标级时区表** `data/timezones.json` (build 时用 timezonefinder 预生成 67 城 `by_coords` + 国家级 `by_country` 兜底,运行时零依赖);引擎按节点 base_lat/base_lon 规范化到 4 位小数查表
  - **Worker realm**: `config['timezone']` 覆盖 (geoip 用 setdefault,手动值优先,Camoufox PR #563 生效)
  - **主线程 realm**: Camoufox 152 build 的 config 时区不作用于主文档 (实测恒 UTC),另用 playwright `add_init_script` 引擎级注入强改 Intl/Date 全族 (DST 动态、函数伪装 native code)
  - 两 realm 同源同一 IANA;经纬度/locale/WebRTC 仍由 geoip 按出口 IP 自洽。已有节点无需重注册 (坐标已在库)
- 引擎侧改动,Agent 不受影响 (仅 bump MASTER_VERSION)

## [v5.6.1-fork] - 2026-09-07

### 🐛 Fixes

- **OTA 重铸证书后 TOFU 假阳性 MITM 告警** — Agent 静默升级会强制销毁并重铸 TLS 自签证书,但注册 UPSERT 不更新 DB 锁定指纹 → 升级后 Master 下发任何指令都报"证书指纹与锁定值不符,疑似中间人攻击" (v5.6.0 狗粮测试实测抓到)。修复: 带 PSK 的合法注册时同步清空 `cert_fp` (合法轮换点, 下次指令 TOFU 重新首次信任新证书); 无 PSK 的老版注册不清指纹, MITM 防护不弱化

## [v5.6.0-fork] - 2026-09-07

### ✨ Features

- **Safe OTA: TG 一键升级安全加固** — 三条 OTA 链路 (Agent 单节点 / 全网 Agent / Master 自升级) 统一补齐三项防护:
  - **tag 锚定** — 升级不再拉 main 分支现状,改为读 version.txt 版本号后从 `v{VER}-fork` tag 拉取 MANIFEST 与安装脚本 (同 tag 内自洽);版本可复现可回滚
  - **版本守卫** — 远端不比本地新即跳过: Agent 侧跳过发 TG 回执 (按钮有反馈),Master 侧 TG 提示"已最新",根除"升级按钮变重装按钮"
  - **Master 自升级补 MANIFEST 验签** — 此前仅 bash -n 语法检查即 root 执行,现与 Agent 侧 V3 修复对齐: sha256 强比对 + 熔断告警
- **全舰队 OTA 确认弹窗展示目标版本** — 下发前可见将升级到哪个版本

### 🐛 Fixes

- **Agent OTA 下载失败静默** — 此前 MANIFEST/install.sh 拉取无超时无重试且 `curl || VAR=""` 判空逻辑失效 (文件存在即非空字符串),现补 connect-timeout + retry + `-s` 文件级判空

## [v5.5.0-fork] - 2026-09-07

### ✨ Features

- **地理跟随出口 IP (geoip=True)** — 浏览器地理 (时区/经纬度/locale) 改由 Camoufox `geoip=True` 按 SOCKS 出口 IP 自动推导。四信道同源于同一 IP,天生自洽,根除此前"手动模板拼接 tz/lat/lon/locale 可能自相矛盾"的风险 (如东京 IP 配 UTC 时区);并自动对齐 WebRTC 到出口 IP、关闭 IPv6 防双栈泄漏。走 proxy 时 geoip 通过隧道查目标机真实出口 IP。经评估放弃 GeoSpoof 浏览器扩展方案 (要求 Firefox ≥140,而 Camoufox 内核为 135;且其地理配置依赖 popup 交互,与无人值守架构冲突)
- **区域模板降级为纯行为剧本** — `load_persona` 产出的 lang_params (Google gl/hl)、static_urls (白名单)、keywords、lat/lon (Maps 城市级驻留) 全部保留,继续按 region 决定"装成哪国人上网";地理由 geoip 接管,行为由 region 控制,分工明确

### 🐛 Fixes

- **engine_setup 补 GeoIP 数据库校验** — geoip=True 运行时必需 MaxMind mmdb,`camoufox fetch` 虽会顺带下载但存在软失败风险;现显式校验 mmdb 可用性,缺失则单独补拉,堵死"缺库导致会话 UnknownIPLocation 崩溃"的坑

## [v5.1.0-fork] - 2026-09-06

### ✨ Features

- **节点级指纹持久化** — 一个节点 = 一套固定设备身份。Camoufox 默认每次启动随机重掷指纹 (BrowserForge 指纹 + canvas/audio/fonts 噪声种子,上游 #442 未解决),与"每个 IP 上的稳定真人"身份模型矛盾。现首次会话生成的完整指纹落盘 `<profile>/fingerprint.json`、噪声种子落盘 `seeds.json`,后续会话经 `fingerprint=` + `config=` (种子预置,`set_into` 尊重已存在键) 回灌同一套身份;跨节点指纹天然隔离;损坏文件自动重新生成 (换设备身份,日志可查)

## [v5.0.0-fork] - 2026-09-06

### 💥 Breaking Changes (curl 引擎退役)

- **移除本地 curl 养护引擎** — `mod_google.sh` / `mod_trust.sh` / `runner.sh` 删除;所有养护流量由 Master 的 Camoufox 浏览器引擎执行。Agent 本机仅保留: 质量探测 (mod_quality)、TG 报表、webhook 指令面、每日维护巡检
- **安装链收敛为单一权威** — 移除与 `core/install.sh` 平行的模块化安装链 (`install/build_agent.sh` / `ui_menu` / `net_engine` / `sys_daemon`);根 `install.sh` 现在经 MANIFEST 哈希门禁直接引导 `core/install.sh`。此前模块化链不含任何安全修复,存在并行绕过面
- **Agent 侧路由收敛** — webhook 移除 `/trigger_run` / `/trigger_google` / `/trigger_trust` / `/trigger_toggle`;Master 移除 all_run / toggle / 模块触发按钮与 enable_google/enable_trust 列
- **updater 瘦身** — UA 池 / 关键词 / 区域模板每日同步删除 (Agent 不再本地养护);仅保留探针完整性巡检 + 日志瘦身,运行时零下载
- **UA 指纹工厂退役** — `data/user_agents.txt`、`scripts/ua_generator.py`、`ua_factory.yml` workflow 删除 (指纹由 Camoufox 自洽管理)

### 🐛 Bug Fixes

- **更正历史遗留**: v4.4.0 提交中宣称的 updater.sh mktemp 转换实际未生效 (Windows python3 stub 静默吞掉编辑);本版已随相关代码块整体删除,状态一致

## [v4.6.0-fork] - 2026-09-06

### 🐛 Bug Fixes

- **【关键】引擎 persona 数据流修复** — 原实现依赖 Master 装机时拉取已注册节点的区域模板,但 Master 先装、节点后注册(装机时 DB 为空),引擎将回退到错误默认 persona。现改为: 注册报文携带 `LANG_PARAMS/BASE_LAT/BASE_LON`(节点装机时选定的城市坐标与语言),Master 入库,调度器直传会话引擎;关键词由调度器按需拉取;装机时点不再拉区域模板

### ✨ Features

- **本地 curl 养护模式选择** — Agent 装机新增 [3.1/7]: 引擎代管(默认,本地 curl 模块关闭且不再部署 20 分钟 runner 巡逻)或本地经典模式;`mod_quality` 质量探测与 TG 报表在两种模式下均保留

### 🔧 Improvements

- **卸载完整化** — Agent 卸载移除 `sentinel-tunnel` 隧道账户及家目录;Master 卸载停止/抹除引擎双守护 (tunnels/engine) 并镇压残留引擎进程
- **隧道账户防锁定** — `usermod -p '*'` 规避 useradd 默认 `!` 密码字段导致的 sshd 锁定账户边缘拒绝

## [v4.5.2-fork] - 2026-09-06

### ✨ Features

- **引擎区域自检 (移植 mod_google 三核验证)** — 每次会话尾部探测实际区域: google.com 落地域名 (送中 IP 会 302 至 google.com.hk) + YouTube contentRegion;判定 OK / DRIFT (漂移) / SINICIZED (送中) 落盘 `<node>.region`,供告警与趋势消费

## [v4.5.1-fork] - 2026-09-06

### ✨ Features

- **调度器并行化** — 由串行/批处理改为持续工作池模型: `ENGINE_CONCURRENCY` (默认 2) 个并发槽位,槽位空闲即补位;单会话 30min 硬超时防占槽;同节点永不双开;节点级 90min 最小间隔保留

## [v4.5.0-fork] - 2026-09-06

### ✨ Features

- **浏览器引擎 (Camoufox) 集成** — 养护流量由 curl 升级为真指纹浏览器: Master 安装时自动部署 venv + Camoufox + 会话调度器;流量经每节点 SSH SOCKS 隧道出口 (Agent 侧仅需粘贴隧道公钥,专用低权账户仅转发无 shell)
- **拟人会话引擎** — 每节点 persona (时区/语言/地理坐标来自区域模板+时区表)、持久 profile、真实浏览行为 (搜索区域关键词、点击结果、News、区域白名单站点、拟人停留滚动),不注入 gl/hl URL 参数
- **隧道池管理** — 按 DB 节点自动建/撤 `ssh -D` 隧道,断线重拉,端口映射持久化
- **防火墙限源自动化** — Agent 安装输入 Master 出口 IP,指令端口仅对该来源放行 (ufw/firewalld/iptables 全覆盖,含历史全网规则收口)
- **注册报文安全** — 携带 PSK 的注册消息解析后立即删除,不留聊天历史

## [v4.4.0-fork] - 2026-09-06

### 🔒 Security (安全审计修复)

本版本为 jasper-khan fork 的首个安全加固版本，修复对 main @ af400c8 全量审计发现的 6 项漏洞：

- **V1 (Critical) 探针供应链 RCE** — ip.sh 探针 vendor 进仓库 (`data/probe/`) 并锁定 SHA-256；`mod_quality.sh` 执行前强制哈希门禁；彻底删除运行时第三方下载 (含 `IP.Check.Place` 零校验回退)
- **V2 (High) 指令通道 PSK 弱密钥** — 每节点独立 256-bit `NODE_PSK` 替代共享低熵 chat_id；401 统一同文响应摧毁爆破预言机；单 IP 限速封禁；TOFU 证书指纹锁定；安装器支持防火墙限源放行
- **V3 (Medium-High) OTA/安装链无签名** — 新增 `MANIFEST.sha256` 哈希锁定清单 (生成器 `scripts/gen_manifest.sh`)；Agent OTA 与两条安装引导链下载后强制哈希比对，不符熔断
- **V4 (Medium) 跨节点重放与签名降级** — 移除 V1 降级签名路径；独立 PSK 同时消除跨舰队签名重放
- **V5 (Low) 可预测 /tmp 路径** — updater/OTA/master OTA 临时文件全部 `mktemp`；runner 锁文件移入安装目录；调试日志移入 `MASTER_DIR/logs` 并限权
- **V6 (Low) 运行面加固** — 500 响应不再回传内部异常；webhook 并发上限 24 线程

### 🧭 Fork 基础

- 全部数据源/安装源/OTA 源指向本仓库 `jasper-khan/IP-Sentinel`

## [v4.3.4] - 2026-08-26

### ✨ Features
- **全舰队切换 Bot 凭证** (#102) — 更换 TG Bot 不再需要逐台卸载重装。Master 主菜单新增「🔁 全舰队切换 Bot 凭证」按钮：填写新 Token + Chat ID 后，司令部先 getMe 验证，再向所有开启 OTA 权限的节点批量下发切换指令；各节点自动完成凭证验证、向新 Bot 推送注册回执、原子重写本地配置，Chat ID 变更时自动重启守护进程完成 HMAC 密钥轮换
- **Agent 端新增 /trigger_reconfig 路由** — 复用 b64 安全 Base64 载荷与 HMAC 签名鉴权；ENABLE_OTA=false 的节点自动熔断（与 Master 下发范围对齐）；先推注册后改配置，任一步失败旧凭证保持完好

### 🐛 Bug Fixes
- **修复 TG API 无效凭证返回 HTTP 401 时 Agent 误报 500** — urllib 对非 2xx 抛异常，现捕获 HTTPError 并解析响应体，正确回传 403 + 失败原因

## [v4.3.2] - 2026-07-24

### ✨ Features
- **新增重新发送注册指令** — Master 重新部署导致 Agent 节点信息丢失时，无需重新安装 Agent，直接运行 `bash /opt/ip_sentinel/core/install.sh` 选择选项 3，一键向 Telegram 推送注册命令即可恢复节点连接
- **添加布法罗地区信息** (#100)
- **注入尔湾 (Irvine) 节点** (#98)
- **扩编芝加哥 (Chicago) 节点** (#90)

### 🐛 Bug Fixes
- **修复模块化入口缺少选项3** — `install/ui_menu.sh` 同步新增重新注册功能（实际运行走此入口）
- **Telegram MarkdownV2 消息换行乱码** — `\n` 字面量改为实际换行，特殊字符正确转义

### 🎨 Improvements
- **暗黑模式星标图表修复** — 采用 GitHub 原生深色主题渲染，坐标轴不再隐形
- **升级星标趋势图引擎** — 自研渲染引擎，彻底摆脱第三方服务 502 问题

### 🔒 Security
- **添加 .gitignore** — 防止密钥泄露

## [v4.3.1] - 2026-07-24

### ✨ Features
- 分布式 VPS IP 养护系统 v4.3.1
- Master-Agent 架构，Telegram Bot 控制
- Agent 每20分钟执行养护循环（mod_google 区域模拟搜索、mod_quality IP质量探测、mod_trust 白名单访问）
- HMAC-SHA256 动态签名 60 秒有效期
- WARP 过滤、防火墙自动管理
- Python3 标准库零第三方依赖
