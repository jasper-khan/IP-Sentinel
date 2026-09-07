# Changelog

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
