# Security Policy 安全策略

## 支持版本

| 分支 | 状态 |
|------|------|
| main (fork) | ✅ 持续维护 |
| 上游 hotyue/IP-Sentinel | 由上游维护，本 fork 不追踪其 main |

## 漏洞报告

**请勿通过公开 issue 报告安全漏洞。**

- 本仓库：使用 GitHub Security 标签页 "Report a vulnerability" 私密披露
- 响应时限：7 天内确认，30 天内给出修复或缓解

## 已修复的安全问题

本 fork 基于 2026-09-06 的全量安全审计完成了以下修复（详见 CHANGELOG v4.4.0-fork）：

| 编号 | 严重度 | 问题 | 修复 |
|------|--------|------|------|
| V1 | Critical | 探针第三方下载 + 子串匹配"校验" + 零校验回退源 → root RCE | 探针 vendor + SHA-256 门禁，删除全部运行时第三方下载 |
| V2 | High | 指令通道 PSK 为低熵 chat_id，端口全网开放 | 每节点独立 256-bit PSK + 401 同文 + 限速封禁 + TOFU 证书锁定 + 防火墙限源 |
| V3 | Medium-High | OTA/安装链实时拉取 main 以 root 执行，无签名 | MANIFEST.sha256 哈希锁定，下载即校验，不符熔断 |
| V4 | Medium | 跨节点签名重放 + V1 签名降级路径 | 独立 PSK；移除降级路径 |
| V5 | Low | root 写可预测 /tmp 路径；调试日志泄露 chat_id | mktemp / 日志移入限权目录 |
| V6 | Low | 500 回传内部异常；无并发上限 | 通用错误文案 + 24 线程上限 |

## 发布签名模型

- 所有以 root 执行的分发文件收录于 `MANIFEST.sha256`
- 发布流程：`bump version.txt → bash scripts/gen_manifest.sh → commit & tag`
- Agent/OTA/安装链下载任何受锁文件前强制比对清单，缺失或不匹配一律熔断拒绝执行
- 升级签名体系（minisign/ed25519）列入 roadmap
