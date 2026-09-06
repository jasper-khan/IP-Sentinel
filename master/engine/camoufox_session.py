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
    """组装 Camoufox persona。

    优先级: 注册报文携带的 DB 字段 (lang_params/lat/lon,精确到节点装机时
    选定的城市) > 本地区域模板 json > 默认值。
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


def run_session(node, region_code, socks_port, persona, keywords):
    """一次完整拟人会话。任何浏览器层异常只记日志,不抛出 (调度器兜底)。"""
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

    # [persona 注入] timezone 必须经 config 传递 (camoufox 构造函数无 timezone 参数);
    # 与持久化噪声种子合并——set_into 只在键不存在时写入,预置即锁定
    node_config = dict(node_seeds)
    node_config["timezone"] = persona["timezone"]

    # geolocation 为 dict 格式;locale 用 语言-地区 全格式 (en-US 而非 en)
    locale_full = persona["locale"]
    if "-" not in locale_full:
        cc = region_code.upper()
        common = {"US": "en-US", "GB": "en-GB", "FR": "fr-FR", "DE": "de-DE",
                  "JP": "ja-JP", "KR": "ko-KR", "TW": "zh-TW", "SG": "en-SG",
                  "AU": "en-AU", "CA": "en-CA", "IN": "en-IN"}
        locale_full = common.get(cc, "en-US")

    log("启动会话: region=%s tz=%s locale=%s lat,lon=(%.4f,%.4f) proxy=%s"
        % (region_code, persona["timezone"], locale_full,
           persona["lat"], persona["lon"], proxy_desc))

    with Camoufox(
        fingerprint=node_fp,
        config=node_config,
        i_know_what_im_doing=True,          # 自定义持久化指纹为有意行为
        proxy=proxy,
        locale=locale_full,
        geolocation={"latitude": persona["lat"], "longitude": persona["lon"]},
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
    """区域判定落盘 + 漂移/送中标记 (监控层 KPI)。

    证据分级 (避免单信号定罪 — 实测曾因孤立 jump 样本误报送中):
    - 两信号一致 → 定罪 (SINICIZED / DRIFT)
    - 仅单信号矛盾且另一信号支持目标 → WATCH (观察,待复现)
    - yt=CN 与 jump→com.hk 互为强证据,任一与目标冲突即升级
    """
    target = region_code.upper()
    jump = (probe.get("jump") or "").lower()
    observed = probe.get("yt", "")

    verdict = "OK"
    notes = []

    # 信号 1: 落地域名 (google.com → google.com.hk 是中文区重定向)
    jump_bad = False       # jump 与目标矛盾
    jump_sinic = False     # jump 指向中文区
    if jump:
        expected_domains = {
            "US": ("www.google.com", "google.com"),
            "HK": ("www.google.com.hk", "google.com.hk"),
            "TW": ("www.google.com.tw", "google.com.tw"),
            "JP": ("www.google.co.jp", "google.co.jp"),
            "UK": ("www.google.co.uk", "google.co.uk"),
        }
        ok_domains = expected_domains.get(target, ())
        if jump in ("www.google.com.hk", "google.com.hk") and "google.com.hk" not in ok_domains:
            jump_sinic = True
            notes.append("jump→com.hk")
        elif ok_domains and jump not in ok_domains:
            jump_bad = True
            notes.append("jump→" + jump)
        elif not ok_domains and jump not in ("www.google.com", "google.com"):
            jump_bad = True
            notes.append("jump→" + jump)

    # 信号 2: YouTube contentRegion
    yt_bad = False
    yt_sinic = False
    if observed == "CN":
        yt_sinic = True
        notes.append("yt=CN")
    elif observed and observed != target:
        yt_bad = True
        notes.append("yt=" + observed)

    # 证据合成
    # - yt=CN: 最强单信号,YouTube 明确判 CN → 直接定罪
    # - jump→中文区: yt 佐证漂移→定罪; yt 支持目标或未测→观察
    # - 双信号一致漂移 → DRIFT (酷鸭: jump=US yt=US 目标 HK)
    # - 单信号漂移且另一信号缺失/支持目标 → WATCH
    if yt_sinic:
        verdict = "SINICIZED"
    elif jump_sinic:
        verdict = "SINICIZED" if yt_bad else "WATCH"
    elif jump_bad and yt_bad:
        verdict = "DRIFT"
    elif jump_bad:
        verdict = "WATCH" if (not observed or observed == target) else "DRIFT"
    elif yt_bad:
        verdict = "DRIFT" if jump else "WATCH"

    log("区域自检: target=%s Jump=%s YT=%s -> %s%s"
        % (target, jump or "unknown", observed or "unknown", verdict,
           (" (" + ",".join(notes) + ")") if notes else ""))

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
    ap.add_argument("--lang-params", default=None,
                    help="注册报文携带的区域参数 (hl=xx&gl=XX),优先于模板")
    ap.add_argument("--lat", default=None, help="注册报文携带的纬度")
    ap.add_argument("--lon", default=None, help="注册报文携带的经度")
    args = ap.parse_args()

    NODE = args.node
    region_json = args.region_json or find_region_json(args.region)
    persona = load_persona(args.region, region_json,
                           lang_params=args.lang_params,
                           lat=args.lat, lon=args.lon)
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
