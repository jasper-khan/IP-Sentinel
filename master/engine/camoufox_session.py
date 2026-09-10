#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IP-Sentinel 浏览器养护引擎 (Camoufox 会话)
==========================================
职责: 对单个目标节点执行一次拟人养护会话。

设计要点 (审计与方案讨论结论的落地):
- 流量经该节点专属 SSH SOCKS 隧道出口 (proxy 由参数注入)
- 时区: 节点城市坐标查 data/timezones.json 定 IANA, 经 config['timezone']
  手动注入 (geoip 时区粗判不可靠, 实测 LA 出口被判成 Chicago); 其余地理
  (经纬度/locale/WebRTC) 由 geoip=True 按出口 IP 推导, 四信号保自洽
- 每节点持久 profile (cookies/身份跨会话稳定)
- 行为层: Google 搜索区域关键词 + news + 区域白名单站点,
  真实停留/滚动;不注入 gl/hl URL 参数 (curl 时代痕迹)
- UA/指纹完全交给 Camoufox 自洽管理,不外部注入
- 区域自检用"干净观测者"探针: 会话主体浏览器结束后单独开一个非持久、
  无 profile/cookie/指纹注入的全新 Camoufox 实例, 走同一隧道裸问三核。
  绝不复用养护浏览器 —— 其累积 cookie 会让 Google 凭偏好作答而非凭 IP
  (对齐上游 PR #82 剥离探测身份原则的浏览器版)

用法:
  camoufox_session.py --node <NODE_NAME> --region <REGION_CODE> \
      --socks-port <10801+> [--region-json <path>] [--keywords <path>]
"""

import argparse
import json
import os
import random
import re
import sys
import time
from urllib.parse import urlparse

MASTER_DIR = os.environ.get("MASTER_DIR", "/opt/ip_sentinel_master")
TZ_MAP_PATH = os.path.join(MASTER_DIR, "data", "timezones.json")
PROFILE_ROOT = os.path.join(MASTER_DIR, "profiles")
ENGINE_LOG = os.path.join(MASTER_DIR, "logs", "engine.log")

# Camoufox 可选区域模板根 (安装器随引擎一并拉取)
REGION_DATA_ROOT = os.path.join(MASTER_DIR, "data", "regions")
KEYWORDS_ROOT = os.path.join(MASTER_DIR, "data", "keywords")
WHITELIST_ROOT = os.path.join(MASTER_DIR, "data", "whitelist")

NODE = "-"   # 由 main() 按 --node 覆盖


def log(msg):
    line = "[%s] [Engine ] [%s] %s" % (
        time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime()), NODE, msg)
    try:
        os.makedirs(os.path.dirname(ENGINE_LOG), exist_ok=True)
        with open(ENGINE_LOG, "a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass
    print(line)


def resolve_timezone(region_code, lat, lon):
    """按节点坐标定 IANA 时区 (坐标级); 坐标未命中回退国家级; 再未命中 None。
    时区表 build 时用 timezonefinder 预生成 (data/timezones.json), 运行时无依赖。"""
    try:
        with open(TZ_MAP_PATH, encoding="utf-8") as f:
            tzmap = json.load(f)
    except (OSError, ValueError):
        return None
    by_coords = tzmap.get("by_coords", {})
    by_country = tzmap.get("by_country", {})
    try:
        key = "%.4f,%.4f" % (round(float(lat), 4), round(float(lon), 4))
        if key in by_coords:
            return by_coords[key]
    except (TypeError, ValueError):
        pass
    return by_country.get((region_code or "").upper())


def find_region_json(region_code):
    """在 data/regions/<CC>/... 下定位该区域的模板 json (单区域节点只装一份)。"""
    base = os.path.join(REGION_DATA_ROOT, region_code)
    if not os.path.isdir(base):
        return None
    for root, _dirs, files in os.walk(base):
        for name in files:
            if name.endswith(".json"):
                return os.path.join(root, name)
    return None


def load_persona(region_code, region_json_path, lang_params=None, lat=None, lon=None):
    """组装 persona 的"行为剧本"部分。

    注意: 浏览器地理分两路 —
      - timezone: 本函数按城市坐标查表产出, 是唯一生效的时区来源
        (config['timezone'] 手动注入, 压过 geoip 的时区粗判)
      - 经纬度/locale/WebRTC: geoip=True 按出口 IP 推导, 不从此处注入
    其余字段仅供行为层使用:
      - lat/lon      → Google Maps 城市级驻留 URL (与 geoip 同区域)
      - static_urls  → 信用净化白名单深访站点
      - lang_params  → Google 搜索 gl/hl (按 region 定"装成哪国人搜索")
      - locale       → 保留字段 (浏览器 locale 已由 geoip 接管, 未使用)

    优先级: 注册报文携带的 DB 字段 (lang_params/lat/lon,装机选定城市) >
    本地区域模板 json > 默认值。
    """
    # DB 字段优先 (来自该节点 Agent 注册时的区域配置)
    effective_lang = lang_params or ""
    effective_lat, effective_lon = lat, lon

    template = {}
    if region_json_path and os.path.isfile(region_json_path):
        with open(region_json_path, encoding="utf-8") as f:
            template = json.load(f)

    google_mod = template.get("google_module", {})
    if not effective_lang:
        effective_lang = google_mod.get("lang_params", "")
    if effective_lat is None:
        effective_lat = google_mod.get("base_lat", 0) or 0
    if effective_lon is None:
        effective_lon = google_mod.get("base_lon", 0) or 0

    try:
        lat_v = float(effective_lat)
    except (TypeError, ValueError):
        lat_v = 0.0
    try:
        lon_v = float(effective_lon)
    except (TypeError, ValueError):
        lon_v = 0.0

    # lang_params "hl=zh-HK&gl=HK" -> locale "zh-HK"
    locale = "en-US"
    for kv in effective_lang.split("&"):
        if kv.startswith("hl="):
            hl = kv[3:].strip()
            if hl:
                locale = hl
            break

    timezone = resolve_timezone(region_code, lat_v, lon_v)

    # static_urls: 优先按需拉取的国家白名单 (master 无区域模板), 回退模板
    static_urls = load_whitelist(region_code) or template.get("trust_module", {}).get("static_urls", [])
    return {
        "locale": locale,
        "timezone": timezone,
        "lat": lat_v,
        "lon": lon_v,
        "static_urls": static_urls,
    }


def load_keywords(region_code):
    path = os.path.join(KEYWORDS_ROOT, "kw_%s.txt" % region_code)
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="ignore") as f:
        kws = [line.strip() for line in f if line.strip()]
    return kws


def load_whitelist(region_code):
    """按国家读白名单站点 (IP 信用净化深访目标)。调度器按需拉 wl_<CC>.txt
    (curl->浏览器迁移时 static_urls 投递漏接的补齐: 白名单为全国性站点, 不分城市)。"""
    path = os.path.join(WHITELIST_ROOT, "wl_%s.txt" % region_code)
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="ignore") as f:
        return [line.strip() for line in f if line.strip().startswith("http")]


def human_dwell(min_s=20, max_s=70):
    """拟人停留: 大多为短阅读,偶发长阅读。"""
    if random.random() < 0.15:
        return random.randint(120, 300)
    return random.randint(min_s, max_s)


def safe_url(url):
    try:
        p = urlparse(url)
        return p.scheme in ("http", "https") and bool(p.netloc)
    except ValueError:
        return False


# ==========================================================
# [指纹持久化] 一个节点 = 一套固定设备身份
# Camoufox 默认每次启动随机重掷指纹 (BrowserForge + canvas/audio/fonts
# 噪声种子,上游 issue #442 未解决)。真实设备不会每天换脸——本引擎
# 在 profile 旁持久化首次生成的完整指纹与噪声种子,后续会话回灌:
#   <PROFILE_ROOT>/<node>/fingerprint.json  完整 BrowserForge 指纹
#   <PROFILE_ROOT>/<node>/seeds.json        canvas/audio/fonts 噪声种子
# 噪声种子经 config 预置 (camoufox utils.set_into 尊重已存在的键),
# 不再每启动随机。
# ==========================================================
FINGERPRINT_FILE = "fingerprint.json"
SEEDS_FILE = "seeds.json"


def _load_fingerprint(fp_path):
    """从磁盘重建 BrowserForge Fingerprint 对象;损坏则返回 None。"""
    if not os.path.isfile(fp_path):
        return None
    try:
        from browserforge.fingerprints import (
            Fingerprint, ScreenFingerprint, NavigatorFingerprint, VideoCard,
        )
        with open(fp_path, encoding="utf-8") as f:
            d = json.load(f)
        return Fingerprint(
            screen=ScreenFingerprint(**d["screen"]),
            navigator=NavigatorFingerprint(**d["navigator"]),
            headers=d["headers"],
            videoCodecs=d["videoCodecs"],
            audioCodecs=d["audioCodecs"],
            pluginsData=d["pluginsData"],
            battery=d["battery"],
            videoCard=VideoCard(**d["videoCard"]) if d["videoCard"] else None,
            multimediaDevices=d["multimediaDevices"],
            fonts=d["fonts"],
            mockWebRTC=d["mockWebRTC"],
            slim=d["slim"],
        )
    except Exception:
        return None


def obtain_fingerprint(profile_dir):
    """取该节点的持久化指纹;首次会话生成 Firefox 指纹并存盘。"""
    fp_path = os.path.join(profile_dir, FINGERPRINT_FILE)

    fp = _load_fingerprint(fp_path)
    if fp is not None and "Firefox" in fp.navigator.userAgent:
        log("指纹复用 (持久化): %s" % fp.navigator.userAgent[:80])
        return fp

    # 首次: 生成 Firefox 指纹 (camoufox 同款生成器) 并存盘
    from camoufox.fingerprints import generate_fingerprint
    fp = generate_fingerprint()
    with open(fp_path, "w", encoding="utf-8") as f:
        f.write(fp.dumps())
    os.chmod(fp_path, 0o600)
    log("指纹生成并持久化: %s" % fp.navigator.userAgent[:80])
    return fp


def obtain_seeds(profile_dir):
    """取该节点的持久化噪声种子;首次生成并存盘。
    经 config 预置注入后,camoufox 的每启动随机种子不再生效
    (set_into 只在键不存在时写入)。"""
    seeds_path = os.path.join(profile_dir, SEEDS_FILE)

    if os.path.isfile(seeds_path):
        try:
            with open(seeds_path, encoding="utf-8") as f:
                seeds = json.load(f)
            if all(k in seeds for k in ("fonts:spacing_seed", "audio:seed", "canvas:seed")):
                log("噪声种子复用 (持久化)")
                return seeds
        except (OSError, ValueError):
            pass

    seeds = {
        "fonts:spacing_seed": random.randint(1, 4294967295),
        "audio:seed": random.randint(1, 4294967295),
        "canvas:seed": random.randint(1, 4294967295),
    }
    with open(seeds_path, "w", encoding="utf-8") as f:
        json.dump(seeds, f)
    os.chmod(seeds_path, 0o600)
    log("噪声种子生成并持久化")
    return seeds


def run_session(node, region_code, socks_port, persona, keywords, focus="all"):
    """一次完整拟人会话。任何浏览器层异常只记日志,不抛出 (调度器兜底)。

    focus: 会话侧重 (对应原 curl 双模块的产品语义)
      - google: Google 区域纠偏侧重 (首页+多轮搜索点击+News+Maps)
      - trust : IP 信用净化侧重 (区域白名单站点深访)
      - all   : 混合 (自动调度的默认形态)
    """
    from camoufox.sync_api import Camoufox

    profile_dir = os.path.join(PROFILE_ROOT, node)
    os.makedirs(profile_dir, exist_ok=True)

    # [指纹持久化] 该节点的固定设备身份
    node_fp = obtain_fingerprint(profile_dir)
    node_seeds = obtain_seeds(profile_dir)

    # socks_port=0 → 同机模式 (Master 与 Agent 同装),直接本机出口
    if socks_port:
        proxy = {"server": "socks5://127.0.0.1:%d" % socks_port}
        proxy_desc = "socks5://127.0.0.1:%d" % socks_port
    else:
        proxy = None
        proxy_desc = "direct (local egress)"

    # [地理注入] 经纬度/时区/locale 全部交给 geoip=True 按出口 IP 自动推导,
    # 四信道 (tz/lat/lon/locale) 同源于同一 IP,天生自洽;并自动对齐 WebRTC 到
    # 出口 IP,关闭 IPv6 防双栈泄漏。geoip 走 proxy 时通过隧道查目标机出口 IP。
    # persona 的 lat/lon 不再注入浏览器,仅供 Maps 驻留 URL (城市级,同区域)。
    # config 仅承载持久化噪声种子 (set_into 尊重已存在键,指纹身份不被 geoip 覆盖)。
    node_config = dict(node_seeds)

    # [时区对齐] 按节点坐标定 IANA (坐标级, 不用 geoip 粗判 - 实测 geoip 把 LA 判成 Chicago)。
    # config['timezone'] 由 Camoufox 二进制层伪装, 主文档与 Worker 两 realm 均生效
    # (2026-09-10 002 生产实测, camoufox 0.5.6)。
    node_tz = persona.get("timezone")
    if node_tz:
        node_config["timezone"] = node_tz

    log("启动会话: region=%s tz=%s geoip=auto(经纬度/locale跟随出口IP) proxy=%s"
        % (region_code, node_tz or "geoip-default", proxy_desc))

    with Camoufox(
        fingerprint=node_fp,
        config=node_config,
        i_know_what_im_doing=True,          # 自定义持久化指纹为有意行为
        proxy=proxy,
        geoip=True,                         # 地理跟随出口 IP: tz/经纬度/locale 自动自洽 + WebRTC 对齐
        humanize=True,                      # Camoufox 原生拟人光标/滚动
        persistent_context=True,
        user_data_dir=profile_dir,
        headless=True,                      # 自带反 headless 伪装
        block_images=False,
    ) as browser:
        page = browser.new_page()
        page.set_default_timeout(45000)

        act = 1   # 动作序号

        def next_act():
            nonlocal act
            n = act
            act += 1
            return n

        # ==========================================================
        # [focus=google/trust] 会话侧重: 原 curl 双模块的产品语义
        #   google → Google 系动作加量 (双轮搜索 + News + Maps)
        #   trust  → 白名单深访 (3-4 站 + 长停留)
        #   all    → 均衡一轮 (自动调度默认)
        # ==========================================================
        google_rounds = {"google": 2, "all": 1, "trust": 0}[focus]
        trust_picks = {"google": 1, "all": 2, "trust": 4}[focus]

        # --- 动作: Google 首页自然访问 (不注入 gl/hl) ---
        try:
            page.goto("https://www.google.com/", wait_until="domcontentloaded")
            log("动作[%d] google.com 完成" % next_act())
            time.sleep(human_dwell(8, 20))
        except Exception as e:
            log("WARN 动作[1] google.com 失败: %s" % e)

        # --- 动作: 搜索区域关键词 (可多轮) ---
        for _ in range(google_rounds):
            if not keywords:
                break
            kw = random.choice(keywords)
            try:
                page.goto(
                    "https://www.google.com/search?q=" + _q(kw),
                    wait_until="domcontentloaded")
                log("动作[%d] 搜索关键词完成: %s" % (next_act(), kw))
                _human_scroll(page)
                time.sleep(human_dwell())

                # 拟人点击一条搜索结果 (打开后自然返回)
                results = page.locator("div#search a h3").all()
                if results:
                    idx = random.randint(0, min(len(results) - 1, 5))
                    results[idx].click(timeout=15000)
                    time.sleep(human_dwell(15, 40))
                    log("动作[%d] 点击搜索结果[%d]并阅读" % (next_act(), idx))
            except Exception as e:
                log("WARN 搜索动作失败: %s" % e)

        # --- 动作: Google News ---
        if focus in ("google", "all"):
            try:
                page.goto("https://news.google.com/", wait_until="domcontentloaded")
                _human_scroll(page)
                log("动作[%d] news.google.com 完成" % next_act())
                time.sleep(human_dwell())
            except Exception as e:
                log("WARN News 动作失败: %s" % e)

        # --- 动作: Google Maps (纠偏侧重: 区域坐标驻留) ---
        if focus == "google" and persona["lat"]:
            try:
                page.goto(
                    "https://www.google.com/maps/@%.4f,%.4f,15z"
                    % (persona["lat"], persona["lon"]),
                    wait_until="domcontentloaded")
                _human_scroll(page)
                log("动作[%d] Google Maps 驻留完成" % next_act())
                time.sleep(human_dwell(20, 50))
            except Exception as e:
                log("WARN Maps 动作失败: %s" % e)

        # --- 动作: 区域白名单站点深访 ---
        statics = [u for u in persona["static_urls"] if safe_url(u)]
        if statics:
            picks = random.sample(statics, min(len(statics), trust_picks))
            for url in picks:
                try:
                    page.goto(url, wait_until="domcontentloaded")
                    _human_scroll(page)
                    log("动作[%d] 白名单站点完成: %s" % (next_act(), url))
                    time.sleep(human_dwell(30, 80) if focus == "trust" else human_dwell())
                except Exception as e:
                    log("WARN 白名单 %s 失败: %s" % (url, e))

        try:
            page.close()
        except Exception:
            pass

    # ==========================================================
    # [区域自检 · 干净观测者探针] (v5.6.24)
    # 探针绝不复用养护浏览器的持久 profile/cookie —— 那测得的是
    # "浏览器记住了目标区域"而非"Google 对这个 IP 的判定" (上游
    # PR #82 剥离探测身份原则的浏览器版: 上游用干净 curl 裸问)。
    # 这里单独开一个非持久、无 user_data_dir、无指纹/geoip 注入的
    # 全新实例, 走同一条 SOCKS 隧道 → 出口仍是节点 IP, 零累积状态。
    # 注意: 干净请求可能落在 consent 墙 (无同意记录), Jump 核按失效
    # 处理, 裁决由 YT 两核兜底 —— 上游"YT 主导容忍 Jump 失败"的本意。
    # ==========================================================
    probe = {}
    try:
        with Camoufox(
            proxy=proxy,
            headless=True,
            i_know_what_im_doing=True,   # 有意为之: 干净观测者裸问, 不注入 geoip
        ) as probe_browser:
            probe_page = probe_browser.new_page()
            probe_page.set_default_timeout(45000)
            probe = probe_region(probe_page)
        log("区域自检(干净观测者): jump=%s prem=%s music=%s"
            % (probe.get("jump"), probe.get("prem"), probe.get("music")))
    except Exception as e:
        log("WARN 干净探针失败, 本轮无区域自检: %s" % e)
    region_verdict(node, region_code, probe)

    log("会话结束 (focus=%s), profile 已持久化: %s" % (focus, profile_dir))


def _q(text):
    from urllib.parse import quote
    return quote(text)


def _human_scroll(page, steps=None):
    """拟人滚动: 随机步长、随机间歇。"""
    steps = steps or random.randint(3, 7)
    try:
        for _ in range(steps):
            page.mouse.wheel(0, random.randint(220, 700))
            time.sleep(random.uniform(0.4, 1.8))
    except Exception:
        pass


# 目标区域 → 期望落地域名 (Jump 信号判定表; 反向用于域名→国家码展示)
EXPECTED_DOMAINS = {
    "US": ("www.google.com", "google.com"),
    "HK": ("www.google.com.hk", "google.com.hk"),
    "TW": ("www.google.com.tw", "google.com.tw"),
    "JP": ("www.google.co.jp", "google.co.jp"),
    "UK": ("www.google.co.uk", "google.co.uk"),
}
# 域名 → 国家码 (展示用反查; 未知域名原样保留)
_DOMAIN_GL = {d: cc for cc, ds in EXPECTED_DOMAINS.items() for d in ds}
_YT_GL_RE = re.compile(r'"(?:contentRegion|countryCode|GL)":"([A-Za-z]{2})"')


def _domain_to_gl(domain):
    return _DOMAIN_GL.get(domain, domain)


def probe_region(page):
    """三核区域探测 (对齐上游三核雷达, 浏览器版):
    - jump: google.com 落地的最终域名 (被送中 IP 会 302 到 google.com.hk)
    - prem: YouTube Premium 页面暴露的 contentRegion/GL
    - music: YouTube Music 页面暴露的 contentRegion/GL

    注意: 调用方必须传入**干净观测者**页面 (非持久浏览器, 无养护 cookie);
    复用养护浏览器会让 Google 凭 cookie 作答而非凭 IP。干净请求无同意记录时
    可能落在 consent/sorry 墙, 此时 jump 按失效处理 (无信号≠漂移), 由
    YT 两核兜底裁决。
    """
    result = {"jump": "", "prem": "", "music": ""}
    try:
        page.goto("https://www.google.com/", wait_until="domcontentloaded")
        time.sleep(random.randint(2, 6))
        landing = urlparse(page.url).netloc
        # 干净观测者可能落在 consent/sorry 墙 (无同意记录), 非漂移, 按探测失效处理
        if landing and "consent.google" not in landing and "sorry.google" not in landing:
            result["jump"] = landing
    except Exception:
        pass
    for key, url in (("prem", "https://www.youtube.com/premium"),
                     ("music", "https://music.youtube.com/")):
        try:
            page.goto(url, wait_until="domcontentloaded")
            time.sleep(random.randint(2, 5))
            m = _YT_GL_RE.search(page.content())
            if m:
                result[key] = m.group(1).upper()
        except Exception:
            pass
    return result


def region_verdict(node, region_code, probe):
    """三核分级裁决落盘 (Jump + Prem + Music, 2026-09-08 对齐上游三核探针):

    每信号独立归类: support(支持目标) / cn(中文区) / drift(漂移到别处) / fail(失效)
    裁决 (证据分级, 保留早期预警 — 不采用上游"YT权重容忍Jump漂移"):
      - 三核全失效          → PROBE_FAIL (疑似风控拦截)
      - cn 证据 >= 2        → SINICIZED (双证据定罪)
      - cn 证据 = 1 且有支持信号 → WATCH (孤立矛盾, 下轮复核)
      - cn 证据 = 1 且无其他信号  → SINICIZED (YT判CN强信号无矛盾, 维持定罪)
      - 漂移同区 >= 2       → DRIFT (一致跑偏, 酷鸭案例)
      - 漂移 = 1            → WATCH
      - 其余(全支持)        → OK
    历史追加 <node>.verdicts.jsonl (每轮一行, /trend 面板消费);
    最新快照仍写 <node>.region (日报消费)。
    """
    target = region_code.upper()
    jump = (probe.get("jump") or "").lower()
    prem = (probe.get("prem") or "").upper()
    music = (probe.get("music") or "").upper()

    # ---- 信号归类 ----
    sigs = []   # (名称, 类别, 展示值)  类别: support/cn/drift/fail
    if jump:
        ok_domains = EXPECTED_DOMAINS.get(target, ())
        if jump in ("www.google.com.hk", "google.com.hk") and "google.com.hk" not in ok_domains:
            sigs.append(("Jump", "cn", _domain_to_gl(jump)))
        elif ok_domains and jump in ok_domains:
            sigs.append(("Jump", "support", target))
        elif not ok_domains and jump in ("www.google.com", "google.com"):
            sigs.append(("Jump", "support", "US"))
        else:
            sigs.append(("Jump", "drift", _domain_to_gl(jump)))
    else:
        sigs.append(("Jump", "fail", "?"))
    for name, val in (("Prem", prem), ("Music", music)):
        if not val:
            sigs.append((name, "fail", "?"))
        elif val == "CN" and target != "CN":
            sigs.append((name, "cn", val))
        elif val == target:
            sigs.append((name, "support", val))
        else:
            sigs.append((name, "drift", val))

    cats = [c for _, c, _ in sigs]
    cn_n = cats.count("cn")
    support_n = cats.count("support")
    avail = len(sigs) - cats.count("fail")

    # ---- 分级裁决 ----
    if avail == 0:
        verdict = "PROBE_FAIL"
    elif cn_n >= 2:
        verdict = "SINICIZED"
    elif cn_n == 1:
        verdict = "WATCH" if support_n >= 1 else "SINICIZED"
    else:
        # 漂移判定: 非目标、非中文区的漂移信号, 同区 >=2 → DRIFT
        drift_gls = [v for _, c, v in sigs if c == "drift"]
        same_drift = any(drift_gls.count(g) >= 2 for g in set(drift_gls))
        if same_drift:
            verdict = "DRIFT"
        elif drift_gls:
            verdict = "WATCH"
        else:
            verdict = "OK"

    sig_str = " | ".join("%s:%s" % (n, v) for n, _, v in sigs)
    log("区域自检: target=%s %s -> %s" % (target, sig_str, verdict))

    # ---- 落盘: 最新快照 (.region) + 历史追加 (.verdicts.jsonl) ----
    state = {
        "target": target,
        "jump": probe.get("jump"),
        "jump_gl": _domain_to_gl(jump) if jump else "",
        "prem": prem,
        "music": music,
        "verdict": verdict,
        "ts": int(time.time()),
    }
    try:
        with open(os.path.join(PROFILE_ROOT, "%s.region" % node), "w", encoding="utf-8") as f:
            json.dump(state, f)
    except OSError:
        pass
    try:
        import json as _json
        with open(os.path.join(PROFILE_ROOT, "%s.verdicts.jsonl" % node), "a", encoding="utf-8") as f:
            f.write(_json.dumps(state, ensure_ascii=False) + chr(10))
    except OSError:
        pass
    return verdict


def main():
    global NODE
    ap = argparse.ArgumentParser()
    ap.add_argument("--node", required=True)
    ap.add_argument("--region", required=True)
    ap.add_argument("--socks-port", type=int, required=True)
    ap.add_argument("--region-json", default=None)
    ap.add_argument("--lang-params", default=None,
                    help="注册报文携带的区域参数 (hl=xx&gl=XX),优先于模板")
    ap.add_argument("--lat", default=None, help="注册报文携带的纬度")
    ap.add_argument("--lon", default=None, help="注册报文携带的经度")
    ap.add_argument("--focus", default="all", choices=["all", "google", "trust"],
                    help="会话侧重: google=区域纠偏 trust=信用净化 all=混合")
    args = ap.parse_args()

    NODE = args.node
    region_json = args.region_json or find_region_json(args.region)
    persona = load_persona(args.region, region_json,
                           lang_params=args.lang_params,
                           lat=args.lat, lon=args.lon)
    keywords = load_keywords(args.region)

    try:
        run_session(args.node, args.region, args.socks_port, persona, keywords,
                    focus=args.focus)
        return 0
    except ImportError:
        log("FATAL camoufox 未安装 (venv 损坏?)")
        return 2
    except Exception as e:
        log("FATAL 会话异常终止: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
