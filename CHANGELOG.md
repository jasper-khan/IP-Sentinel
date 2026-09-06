# Changelog

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
