#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
IP-Sentinel 浏览器养护引擎 (Camoufox 会话)
==========================================
职责: 对单个目标节点执行一次拟人养护会话。

设计要点 (审计与方案讨论结论的落地):
- 流量经该节点专属 SSH SOCKS 隧道出口 (proxy 由参数注入)
- persona 按节点区域手动设定 (timezone/locale/geolocation/语言),
  不使用 geoip=True —— 区域由区域模板承载,与 IP 地理一致
- 每节点持久 profile (cookies/身份跨会话稳定)
- 行为层: Google 搜索区域关键词 + news + 区域白名单站点,
  真实停留/滚动;不注入 gl/hl URL 参数 (curl 时代痕迹)
- UA/指纹完全交给 Camoufox 自洽管理,不外部注入

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


def load_persona(region_code, region_json_path):
    """从区域模板 + 时区表组装 Camoufox persona。"""
    template = {}
    if region_json_path and os.path.isfile(region_json_path):
        with open(region_json_path, encoding="utf-8") as f:
            template = json.load(f)

    google_mod = template.get("google_module", {})
    lat = float(google_mod.get("base_lat", 0) or 0)
    lon = float(google_mod.get("base_lon", 0) or 0)

    # lang_params "hl=zh-HK&gl=HK" -> locale "zh-HK"
    locale = "en-US"
    lang_params = google_mod.get("lang_params", "")
    for kv in lang_params.split("&"):
        if kv.startswith("hl="):
            hl = kv[3:].strip()
            if hl:
                locale = hl
            break

    timezone = "UTC"
    try:
        with open(TZ_MAP_PATH, encoding="utf-8") as f:
            tz_map = json.load(f)
        timezone = tz_map.get(region_code, "UTC")
    except (OSError, ValueError):
        pass

    static_urls = template.get("trust_module", {}).get("static_urls", [])
    return {
        "locale": locale,
        "timezone": timezone,
        "lat": lat,
        "lon": lon,
        "static_urls": static_urls,
    }


def load_keywords(region_code):
    path = os.path.join(KEYWORDS_ROOT, "kw_%s.txt" % region_code)
    if not os.path.isfile(path):
        return []
    with open(path, encoding="utf-8", errors="ignore") as f:
        kws = [line.strip() for line in f if line.strip()]
    return kws


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


def run_session(node, region_code, socks_port, persona, keywords):
    """一次完整拟人会话。任何浏览器层异常只记日志,不抛出 (调度器兜底)。"""
    from camoufox.sync_api import Camoufox

    profile_dir = os.path.join(PROFILE_ROOT, node)
    os.makedirs(profile_dir, exist_ok=True)

    # socks_port=0 → 同机模式 (Master 与 Agent 同装),直接本机出口
    if socks_port:
        proxy = {"server": "socks5://127.0.0.1:%d" % socks_port}
        proxy_desc = "socks5://127.0.0.1:%d" % socks_port
    else:
        proxy = None
        proxy_desc = "direct (local egress)"

    log("启动会话: region=%s tz=%s locale=%s lat,lon=(%.4f,%.4f) proxy=%s"
        % (region_code, persona["timezone"], persona["locale"],
           persona["lat"], persona["lon"], proxy_desc))

    with Camoufox(
        proxy=proxy,
        locale=persona["locale"],
        timezone=persona["timezone"],
        geolocation=(persona["lat"], persona["lon"]),
        humanize=True,                      # Camoufox 原生拟人光标/滚动
        persistent_context=True,
        user_data_dir=profile_dir,
        headless=True,                      # 自带反 headless 伪装
        block_images=False,
    ) as browser:
        page = browser.new_page()
        page.set_default_timeout(45000)

        # --- 动作 1: Google 首页自然访问 (不注入 gl/hl) ---
        try:
            page.goto("https://www.google.com/", wait_until="domcontentloaded")
            log("动作[1] google.com 完成")
            time.sleep(human_dwell(8, 20))
        except Exception as e:
            log("WARN 动作[1] 失败: %s" % e)

        # --- 动作 2: 搜索区域关键词 ---
        if keywords:
            kw = random.choice(keywords)
            try:
                page.goto(
                    "https://www.google.com/search?q=" + _q(kw),
                    wait_until="domcontentloaded")
                log("动作[2] 搜索关键词完成: %s" % kw)
                _human_scroll(page)
                time.sleep(human_dwell())

                # 拟人点击一条搜索结果 (打开后自然返回)
                results = page.locator("div#search a h3").all()
                if results:
                    idx = random.randint(0, min(len(results) - 1, 5))
                    results[idx].click(timeout=15000)
                    time.sleep(human_dwell(15, 40))
                    log("动作[2b] 点击搜索结果[%d]并阅读" % idx)
            except Exception as e:
                log("WARN 动作[2] 失败: %s" % e)

        # --- 动作 3: Google News ---
        try:
            page.goto("https://news.google.com/", wait_until="domcontentloaded")
            _human_scroll(page)
            log("动作[3] news.google.com 完成")
            time.sleep(human_dwell())
        except Exception as e:
            log("WARN 动作[3] 失败: %s" % e)

        # --- 动作 4: 区域白名单站点 1-2 个 ---
        statics = [u for u in persona["static_urls"] if safe_url(u)]
        if statics:
            picks = random.sample(statics, min(len(statics), random.randint(1, 2)))
            for i, url in enumerate(picks, start=4):
                try:
                    page.goto(url, wait_until="domcontentloaded")
                    _human_scroll(page)
                    log("动作[%d] 白名单站点完成: %s" % (i, url))
                    time.sleep(human_dwell())
                except Exception as e:
                    log("WARN 动作[%d] %s 失败: %s" % (i, url, e))

        # --- 动作 5: 会话尾区域自检 (三核探测 + 漂移/送中落盘) ---
        probe = probe_region(page)
        region_verdict(node, region_code, probe)

        try:
            page.close()
        except Exception:
            pass

    log("会话结束, profile 已持久化: %s" % profile_dir)


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


def probe_region(page):
    """三核区域探测 (移植自 mod_google 自检):
    - jump: google.com 落地的最终域名 (被送中 IP 会 302 到 google.com.hk)
    - yt:   YouTube Premium 页面暴露的 contentRegion/GL
    """
    result = {"jump": "", "yt": ""}
    try:
        page.goto("https://www.google.com/", wait_until="domcontentloaded")
        time.sleep(random.randint(2, 6))
        result["jump"] = urlparse(page.url).netloc
    except Exception:
        pass
    try:
        page.goto("https://www.youtube.com/premium", wait_until="domcontentloaded")
        time.sleep(random.randint(2, 5))
        m = re.search(r'"(?:contentRegion|countryCode|GL)":"([A-Za-z]{2})"', page.content())
        if m:
            result["yt"] = m.group(2).upper()
    except Exception:
        pass
    return result


def region_verdict(node, region_code, probe):
    """区域判定落盘 + 漂移/送中标记 (监控层 KPI)。"""
    target = region_code.upper()
    observed = probe.get("yt", "")
    verdict = "OK"
    if observed == "CN":
        verdict = "SINICIZED"       # 送中告警
    elif observed and observed != target:
        verdict = "DRIFT"           # 区域漂移 (如酷鸭: 目标 HK 实际 US)

    log("区域自检: target=%s Jump=%s YT=%s -> %s"
        % (target, probe.get("jump") or "unknown", observed or "unknown", verdict))

    # 落盘最新判定 (供 TG 告警/趋势展示消费)
    state = {
        "target": target,
        "jump": probe.get("jump"),
        "yt": observed,
        "verdict": verdict,
        "ts": int(time.time()),
    }
    try:
        with open(os.path.join(PROFILE_ROOT, "%s.region" % node), "w", encoding="utf-8") as f:
            json.dump(state, f)
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
    args = ap.parse_args()

    NODE = args.node
    region_json = args.region_json or find_region_json(args.region)
    persona = load_persona(args.region, region_json)
    keywords = load_keywords(args.region)

    try:
        run_session(args.node, args.region, args.socks_port, persona, keywords)
        return 0
    except ImportError:
        log("FATAL camoufox 未安装 (venv 损坏?)")
        return 2
    except Exception as e:
        log("FATAL 会话异常终止: %s" % e)
        return 1


if __name__ == "__main__":
    sys.exit(main())
