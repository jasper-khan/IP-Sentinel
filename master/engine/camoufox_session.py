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


INIT_TZ_JS = r'''// Hardened timezone override — injected via playwright add_init_script.
// TZ 为脚本源码占位符 __TZ__ (运行前 .replace); 偏移全部动态计算 (DST 正确)。
//
// 覆盖 (主文档 realm; Worker 由 Camoufox config['timezone'] 原生覆盖 —
//   2026-09-10 002 实测: Worker 内 Date 构造/getTimezoneOffset/toString/Temporal
//   均已按 config 时区正确, 无需注入):
//   Intl.DateTimeFormat / Date.prototype 读与格式化 / Date 构造器 + Date.parse
//   (歧义串与多参调用的 epoch 校正) / Temporal.Now 五方法 /
//   Function.prototype.toString 注册表掩码 (引擎原生格式)。
//
// 构造器/parse/Temporal/掩码算法移植自 GeoSpoof (MIT, (c) 2026 Anthony Sgro):
// https://github.com/anthonysgro/geospoof — 单 realm init-script 简化移植。
(function () {
  var TZ = "__TZ__";
  // 任何替换前捕获的原生引用
  var _OD = Date;                                     // OriginalDate
  var _origGTZO = Date.prototype.getTimezoneOffset;   // 真实时区 (西为正)
  var _origFTS = Function.prototype.toString;
  var _g = typeof globalThis !== "undefined" ? globalThis : window;

  var _RDTF = Intl.DateTimeFormat;

  // ---- 基础设施: mask/stripConstruct + Function.prototype.toString 掩码 ----
  // (必须最先成功; 失败则整体放弃 — 后面所有域都依赖它)
  try {
    // ---- Function.prototype.toString 注册表掩码 (GeoSpoof function-masking 移植) ----
    // 单点覆盖 + 注册表: 被掩码函数 toString 返回引擎自身的原生格式 (从 Number
    // 的真实输出派生, SpiderMonkey 多行 [native code] 形状得以复现)。取代旧的
    // 逐函数挂 own toString 属性做法 (ownKeys 上可检测)。
    var _reg = new Map();
    var _np = _origFTS.call(Number).split("Number");
    // GeoSpoof function-masking/stripConstruct 移植: 对象方法简写天然无 prototype
    // 属性无 [[Construct]] 槽 (箭头函数也如此但 this 词法绑定不可用 — 这些方法都
    // 依赖动态 this), 原生方法 (getHours 等) 二者皆无, 函数表达式补丁二者皆有,
    // 一句 hasOwnProperty('prototype') 或 try{new fn()} 即可检测。
    function stripConstruct(fn) {
      var w = ({ method() { return Reflect.apply(fn, this, arguments); } }).method;
      return w;
    }
    function mask(fn, name, len) {
      try {
        Object.defineProperty(fn, "length", { value: len, configurable: true, enumerable: false, writable: false });
        Object.defineProperty(fn, "name", { value: name, configurable: true, enumerable: false, writable: false });
        _reg.set(fn, name);
      } catch (e) {}
      return fn;
    }
    var _fts = ({ toString() {
      var n = _reg.get(this);
      if (n !== undefined) return _np[0] + n + _np[1];
      return _origFTS.call(this);
    } }).toString;
    mask(_fts, "toString", 0);
    Function.prototype.toString = _fts;
  } catch (e) { return; }

  // ---- 伪装时区分量解析 (读层, 原有) ----
  // 以下各域独立 try: 单域失败只回退该域, 不影响其余 (避免"半套"状态扩大)
    // `d` 在 TZ 下的本地分量, 及其偏移分钟数 (getTimezoneOffset 约定, 西为正)。
    var _dtfParts = new _RDTF("en-US", { timeZone: TZ, hour12: false,
      year: "numeric", month: "2-digit", day: "2-digit",
      hour: "2-digit", minute: "2-digit", second: "2-digit" });
    function partsOf(d) {
      var map = {};
      var arr = _dtfParts.formatToParts(d);
      for (var i = 0; i < arr.length; i++) map[arr[i].type] = arr[i].value;
      return map;
    }
    function offsetOf(d) {
      var m = partsOf(d);
      var asUTC = Date.UTC(+m.year, m.month - 1, +m.day, (+m.hour) % 24, +m.minute, +m.second);
      return Math.round((d.getTime() - asUTC) / 60000); // minutes behind UTC → getTimezoneOffset convention
    }

    // ---- Intl.DateTimeFormat: force timeZone + patch resolvedOptions ----
    try {
    function patchRO(inst) {
      var ro = inst.resolvedOptions;
      inst.resolvedOptions = stripConstruct(function () {
        var r = ro.apply(this, arguments);
        r.timeZone = TZ;
        return r;
      }); mask(inst.resolvedOptions, "resolvedOptions", 0);
      return inst;
    }
    function DTF() {
      var args = Array.prototype.slice.call(arguments);
      if (args.length < 2 || args[1] == null) args[1] = {};
      if (typeof args[1] === "object" && !args[1].timeZone) args[1].timeZone = TZ;
      var inst = this instanceof DTF
        ? new (Function.prototype.bind.apply(_RDTF, [null].concat(args)))()
        : _RDTF.apply(null, args);
      return patchRO(inst);
    }
    DTF.prototype = _RDTF.prototype;
    DTF.supportedLocalesOf = _RDTF.supportedLocalesOf;
    mask(DTF, "DateTimeFormat", 0);
    Intl.DateTimeFormat = DTF;
    } catch (e) { /* Intl 域失败 → 原生保留 */ }

    // ---- Date.prototype.getTimezoneOffset: DST-correct ----
    try {
    Date.prototype.getTimezoneOffset = stripConstruct(function () { return offsetOf(this); }); mask(Date.prototype.getTimezoneOffset, "getTimezoneOffset", 0);

    // ---- Date.prototype.toString / toTimeString / toDateString / toLocale* ----
    var DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
    var MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"];
    // tz long name via resolved formatter (e.g. "Pacific Daylight Time")
    var _tzNameFmt = new _RDTF("en-US", { timeZone: TZ, timeZoneName: "long" });
    var _tzAbbrFmt = new _RDTF("en-US", { timeZone: TZ, timeZoneName: "short" });
    function tzNames(d) {
      try {
        var lo = _tzNameFmt.formatToParts(d), ab = _tzAbbrFmt.formatToParts(d), L = "", A = "";
        for (var i = 0; i < lo.length; i++) if (lo[i].type === "timeZoneName") L = lo[i].value;
        for (var j = 0; j < ab.length; j++) if (ab[j].type === "timeZoneName") A = ab[j].value;
        return { long: L, abbr: A };
      } catch (e) { return { long: TZ, abbr: TZ }; }
    }
    function pad(n){ return (n < 10 ? "0" : "") + n; }
    function localString(d) {
      var m = partsOf(d), names = tzNames(d), off = offsetOf(d);
      var sign = off <= 0 ? "+" : "-", ao = Math.abs(off);
      var hh = Math.floor(ao / 60), mm = ao % 60;
      var wd = DAYS[new Date(Date.UTC(+m.year, m.month-1, +m.day)).getUTCDay()];
      return wd + " " + MONTHS[m.month-1] + " " + pad(+m.day) + " " + m.year + " " +
             pad((+m.hour)%24) + ":" + m.minute + ":" + m.second + " " +
             "GMT" + sign + pad(hh) + pad(mm) + " (" + names.long + ")";
    }
    function timeString(d) {
      var m = partsOf(d), names = tzNames(d), off = offsetOf(d);
      var sign = off <= 0 ? "+" : "-", ao = Math.abs(off);
      return pad((+m.hour)%24) + ":" + m.minute + ":" + m.second + " GMT" +
             sign + pad(Math.floor(ao/60)) + pad(ao%60) + " (" + names.long + ")";
    }
    function dateString(d) {
      var m = partsOf(d);
      var wd = DAYS[new Date(Date.UTC(+m.year, m.month-1, +m.day)).getUTCDay()];
      return wd + " " + MONTHS[m.month-1] + " " + pad(+m.day) + " " + m.year;
    }
    Date.prototype.toString = stripConstruct(function () { return localString(this); }); mask(Date.prototype.toString, "toString", 0);
    Date.prototype.toTimeString = stripConstruct(function () { return timeString(this); }); mask(Date.prototype.toTimeString, "toTimeString", 0);
    Date.prototype.toDateString = stripConstruct(function () { return dateString(this); }); mask(Date.prototype.toDateString, "toDateString", 0);
    // toLocaleString family: 透传调用方 locales/options, 按 ECMA-402
    // ToDateTimeOptions 单一 needDefaults 模型:
    //   toLocaleString        required="any"  — 给了任一分量/style → 全不注入
    //   toLocaleDateString    required="date" — date 族全空才注入 date 默认
    //   toLocaleTimeString    required="time" — time 族全空才注入 time 默认
    // date 族 = weekday/year/month/day (era/hour12/hourCycle/timeZoneName 不算);
    // time 族 = dayPeriod/hour/minute/second/fractionalSecondDigits。
    // dateStyle/timeStyle 参与"已给"判定且算本族 style; 族专用方法给对方族
    // style 时抛 TypeError (与原生一致)。无 timeZone 时强制 TZ (调用方优先)。
    var _DATE_PROPS = ["weekday", "year", "month", "day"];
    var _TIME_PROPS = ["dayPeriod", "hour", "minute", "second", "fractionalSecondDigits"];
    function hasProp(o, props) {
      for (var i = 0; i < props.length; i++) {
        if (o[props[i]] !== undefined) return true;
      }
      return false;
    }
    function toLocaleImpl(required) {
      return function () {
        var args = Array.prototype.slice.call(arguments);
        var o = (args.length < 2 || args[1] == null || typeof args[1] !== "object") ? {} : args[1];
        var opts = {};
        for (var k in o) opts[k] = o[k];
        var hasDate = hasProp(opts, _DATE_PROPS) || opts.dateStyle !== undefined;
        var hasTime = hasProp(opts, _TIME_PROPS) || opts.timeStyle !== undefined;
        if (required === "date" && opts.timeStyle !== undefined) {
          throw new TypeError("timeStyle is not supported for toLocaleDateString");
        }
        if (required === "time" && opts.dateStyle !== undefined) {
          throw new TypeError("dateStyle is not supported for toLocaleTimeString");
        }
        var need = required === "any" ? !(hasDate || hasTime)
                 : required === "date" ? !hasDate
                 : !hasTime;
        if (need) {
          if (required === "any" || required === "date") {
            opts.year = "numeric"; opts.month = "numeric"; opts.day = "numeric";
          }
          if (required === "any" || required === "time") {
            opts.hour = "numeric"; opts.minute = "numeric"; opts.second = "numeric";
          }
        }
        if (!opts.timeZone) opts.timeZone = TZ;
        return new _RDTF(args[0], opts).format(this);
      };
    }
    Date.prototype.toLocaleString = stripConstruct(toLocaleImpl("any")); mask(Date.prototype.toLocaleString, "toLocaleString", 0);
    Date.prototype.toLocaleDateString = stripConstruct(toLocaleImpl("date")); mask(Date.prototype.toLocaleDateString, "toLocaleDateString", 0);
    Date.prototype.toLocaleTimeString = stripConstruct(toLocaleImpl("time")); mask(Date.prototype.toLocaleTimeString, "toLocaleTimeString", 0);
    } catch (e) { /* 读/格式化域失败 → 原生保留 */ }

    // ---- Date.prototype 本地分量 getter (GeoSpoof date-getters 移植, Firefox 走 formatToParts 路径) ----
    // getHours/getMinutes/getSeconds/getDate/getDay/getMonth/getFullYear 按 TZ 分量读
    try {
    // (构造器 epoch 校正后, 原生 getter 仍按真实时区读 → 会与 toString/gto 矛盾)。
    // getMilliseconds 与时区无关, 原生保留。
    Date.prototype.getHours = stripConstruct(function () {
      try { return +partsOf(this).hour % 24; } catch (e) { return _OD.prototype.getHours.call(this); }
    }); mask(Date.prototype.getHours, "getHours", 0);
    Date.prototype.getMinutes = stripConstruct(function () {
      try { return +partsOf(this).minute; } catch (e) { return _OD.prototype.getMinutes.call(this); }
    }); mask(Date.prototype.getMinutes, "getMinutes", 0);
    Date.prototype.getSeconds = stripConstruct(function () {
      try { return +partsOf(this).second; } catch (e) { return _OD.prototype.getSeconds.call(this); }
    }); mask(Date.prototype.getSeconds, "getSeconds", 0);
    Date.prototype.getDate = stripConstruct(function () {
      try { return +partsOf(this).day; } catch (e) { return _OD.prototype.getDate.call(this); }
    }); mask(Date.prototype.getDate, "getDate", 0);
    Date.prototype.getDay = stripConstruct(function () {
      try {
        var m = partsOf(this);
        return new Date(Date.UTC(+m.year, m.month - 1, +m.day)).getUTCDay();
      } catch (e) { return _OD.prototype.getDay.call(this); }
    }); mask(Date.prototype.getDay, "getDay", 0);
    Date.prototype.getMonth = stripConstruct(function () {
      try { return partsOf(this).month - 1; } catch (e) { return _OD.prototype.getMonth.call(this); }
    }); mask(Date.prototype.getMonth, "getMonth", 0);
    Date.prototype.getFullYear = stripConstruct(function () {
      try { return +partsOf(this).year; } catch (e) { return _OD.prototype.getFullYear.call(this); }
    }); mask(Date.prototype.getFullYear, "getFullYear", 0);
    } catch (e) { /* getter 域失败 → 原生保留 */ }

    // ---- Date.prototype 本地分量 setter (GeoSpoof date-setters 移植, 紧凑通用实现) ----
    try {
    // 语义: 按 TZ 墙钟分量设值。取当前 TZ 分量 → 应用变更 (setUTC* 归一化溢出,
    // setHours(30)/setMonth(12) 滚动正确) → 反解 epoch (双探针 DST)。setTime/setUTC* 为
    // UTC 语义, 原生保留。setMilliseconds 与时区无关, 原生保留。
    function setComponents(d, changes) {
      var m;
      try { m = partsOf(d); } catch (e) { return NaN; }
      var cur = { year: +m.year, month: +m.month, day: +m.day,
                  hour: (+m.hour) % 24, minute: +m.minute, second: +m.second,
                  ms: _OD.prototype.getUTCMilliseconds.call(d) };
      for (var k in changes) cur[k] = changes[k];
      // 归一化溢出: 先搭 1970 框架再 setUTCFullYear/setUTCMonth... (Date.UTC 对
      // 0-99 年自动 +1900 — setFullYear(50) 会变 1950; setUTC* 系列无此陷阱)
      var tmp = new _OD(0);
      tmp.setUTCFullYear(cur.year);
      tmp.setUTCMonth(cur.month - 1, cur.day);
      tmp.setUTCHours(cur.hour, cur.minute, cur.second, cur.ms);
      var asUTC = tmp.getTime();
      if (isNaN(asUTC)) { d.setTime(NaN); return NaN; }
      // asUTC 即"墙上时钟当作 UTC"的 epoch; 反求真实 epoch = asUTC - TZ偏移(该时刻)
      var east = eastOffsetOf(new _OD(asUTC), TZ, 0);
      var e = asUTC - east * 60000;
      var east2 = eastOffsetOf(new _OD(e), TZ, east);
      if (east2 !== east) e = asUTC - east2 * 60000;
      d.setTime(e);
      return d.getTime();
    }
    function defSetter(name, len, apply) {
      Date.prototype[name] = stripConstruct(function () {
        try {
          return setComponents(this, apply(arguments));
        } catch (e) {
          return _OD.prototype[name].apply(this, arguments);
        }
      }); mask(Date.prototype[name], name, len);
    }
    defSetter("setSeconds",      2, function (a) {
      var c = { second: a[0] }; if (a.length > 1) c.ms = a[1]; return c; });
    defSetter("setMinutes",      3, function (a) {
      var c = { minute: a[0] }; if (a.length > 1) c.second = a[1]; if (a.length > 2) c.ms = a[2]; return c; });
    defSetter("setHours",        4, function (a) {
      var c = { hour: a[0] }; if (a.length > 1) c.minute = a[1]; if (a.length > 2) c.second = a[2]; if (a.length > 3) c.ms = a[3]; return c; });
    defSetter("setDate",         1, function (a) { return { day: a[0] }; });
    defSetter("setMonth",        2, function (a) {
      var c = { month: a[0] + 1 }; if (a.length > 1) c.day = a[1]; return c; });
    defSetter("setFullYear",     3, function (a) {
      var c = { year: a[0] }; if (a.length > 1) c.month = a[1] + 1; if (a.length > 2) c.day = a[2]; return c; });
    // setYear (废弃 API): 年份 <100 加 1900
    defSetter("setYear",         1, function (a) { return { year: a[0] < 100 ? a[0] + 1900 : a[0] }; });
    // getYear (废弃 API): 年份-1900 — 与 getFullYear 同路, 需与 getFullYear 自洽
    Date.prototype.getYear = stripConstruct(function () {
      try { return +partsOf(this).year - 1900; } catch (e) { return _OD.prototype.getYear.call(this); }
    }); mask(Date.prototype.getYear, "getYear", 0);
    } catch (e) { /* setter 域失败 → 原生保留 */ }

    // ---- timezone-helpers (GeoSpoof 移植) ----
    // 真实系统 IANA id (原生 Intl 解析; 002 为 UTC, 但代码不依赖该假设)
    var _realTzId = "UTC";
    try { _realTzId = new _RDTF().resolvedOptions().timeZone || "UTC"; } catch (e) {}

    // "GMT+8" / "GMT-5:30" → 东为正的分钟数
    function parseGMTOffset(s) {
      if (s === "GMT" || s === "UTC") return 0;
      var m = /^GMT([+-])(\d{1,2})(?::(\d{2}))?(?::(\d{2}))?$/.exec(s);
      if (!m) return 0;
      var sign = m[1] === "+" ? 1 : -1;
      return sign * (parseInt(m[2], 10) * 60 + parseInt(m[3] || "0", 10) + parseInt(m[4] || "0", 10) / 60);
    }
    // d 时刻 tzId 的 UTC 偏移 (东为正, 分钟), 经原生 shortOffset 分量 (formatter 缓存)
    var _offFmts = {};
    function eastOffsetOf(d, tzId, fallback) {
      try {
        var f = _offFmts[tzId];
        if (!f) f = _offFmts[tzId] = new _RDTF("en-US", { timeZone: tzId, timeZoneName: "shortOffset" });
        var parts = f.formatToParts(d), v = "GMT";
        for (var i = 0; i < parts.length; i++) if (parts[i].type === "timeZoneName") v = parts[i].value;
        return parseGMTOffset(v);
      } catch (e) { return fallback; }
    }
    // 字符串无显式时区标记 → 引擎按真实本地时区解析 (需校正);
    // 纯日期 YYYY-MM-DD 规范即 UTC (不校正)
    function isAmbiguousDateString(str) {
      var s = String(str).trim();
      if (/^\d{4}-\d{2}-\d{2}$/.test(s)) return false;
      if (/Z$/i.test(s)) return false;
      if (/\b(?:UTC|GMT)\b/i.test(s)) return false;
      if (/[+-]\d{2}(?::?\d{2})?$/.test(s)) return false;
      return true;
    }
    // epoch 校正量 (ms): 使真实 TZ 浏览器把同一墙上时钟解析到同一 epoch。
    // 真实侧经 Intl 解析 (与伪装侧同精度); 两轮探针处理 DST 边界穿越。
    // 全程统一东为正约定 (Intl): east=UTC 偏移向东为正, "墙上当 UTC" 换算一律
    // epoch = wallEpoch - east*60000。真实侧 east 直接取值, 不再经西为正翻转。
    function computeEpochAdjustment(parsedDate, fallbackEast) {
      // realEast: 真实时区在该解析时刻的偏移 (东为正)。eastOffsetOf 内部走 Intl
      // (东为正); _origGTZO 是西为正, 仅作 Intl 失败时的兜底换算。
      var realEastFallback = -_origGTZO.call(parsedDate);
      var realEast = eastOffsetOf(parsedDate, _realTzId, realEastFallback);
      // parsedDate.getTime() 是引擎按真实时区解出的 UTC epoch;
      // 墙上时钟 epoch = P + realEast*60000 (把真实时区解释"还原"成墙上读数)
      var wallEpoch = parsedDate.getTime() + realEast * 60000;
      try {
        var spoofEast = eastOffsetOf(new _OD(wallEpoch - fallbackEast * 60000), TZ, fallbackEast);
        if (spoofEast !== fallbackEast) {
          spoofEast = eastOffsetOf(new _OD(wallEpoch - spoofEast * 60000), TZ, fallbackEast);
        }
        return Math.round((realEast - spoofEast) * 60000);
      } catch (e) {
        return Math.round((realEast - fallbackEast) * 60000);
      }
    }

    // ---- Date 构造器 + Date.parse (GeoSpoof date-constructor 移植) ----
    try {
    // 歧义串/多参调用按伪装时区重定 epoch; 显式时区/纯日期/数值原样透传。
    function DateOverride() {
      var nt = new.target;
      var args = Array.prototype.slice.call(arguments);
      var construct = function (ctorArgs) {
        return Reflect.construct(_OD, ctorArgs, nt);
      };
      // 不带 new: 原生 Date() 返回当前时间字符串; 走实例同一条 (被补丁的)
      // toString 路径, 保证 new Date() == Date() 两侧一致
      if (!nt) {
        return new _OD().toString();
      }
      if (args.length === 0) return construct([]);
      if (args.length === 1) {
        var a = args[0];
        if (typeof a === "number") return construct([a]);
        if (typeof a === "string") {
          try {
            var parsed = new _OD(a);
            if (isNaN(parsed.getTime())) return construct([a]);
            if (isAmbiguousDateString(a)) {
              return construct([parsed.getTime() + computeEpochAdjustment(parsed, -offsetOf(parsed))]);
            }
            return construct([a]);
          } catch (e) { return construct([a]); }
        }
        return construct([a]);
      }
      // 多参: 年, 月, [日, 时, 分, 秒, 毫秒] — 原生按真实本地时区解析, 需校正
      var multi = [args[0], args[1], args[2] === undefined ? 1 : args[2],
                   args[3] === undefined ? 0 : args[3], args[4] === undefined ? 0 : args[4],
                   args[5] === undefined ? 0 : args[5], args[6] === undefined ? 0 : args[6]];
      try {
        var pm = Reflect.construct(_OD, multi);
        return construct([pm.getTime() + computeEpochAdjustment(pm, -offsetOf(pm))]);
      } catch (e) { return construct(multi); }
    }

    DateOverride.prototype = _OD.prototype;
    Object.defineProperty(DateOverride, "name", { value: "Date", configurable: true, enumerable: false, writable: false });
    Object.defineProperty(DateOverride, "length", { value: 7, configurable: true, enumerable: false, writable: false });
    // 拷贝全部静态属性 (now/UTC 等; 跳过 prototype/name/length/parse)
    var _skip = { prototype: 1, name: 1, length: 1, parse: 1 };
    var _ownNames = Object.getOwnPropertyNames(_OD);
    for (var oi = 0; oi < _ownNames.length; oi++) {
      var op = _ownNames[oi];
      if (_skip[op]) continue;
      var od = Object.getOwnPropertyDescriptor(_OD, op);
      if (od) Object.defineProperty(DateOverride, op, od);
    }
    // Date.parse: 与构造器同源的歧义校正
    var dateParseOverride = function (str) {
      try {
        var epoch = _OD.parse(str);
        if (isNaN(epoch)) return NaN;
        if (isAmbiguousDateString(str)) {
          var pp = new _OD(epoch);
          return epoch + computeEpochAdjustment(pp, -offsetOf(pp));
        }
        return epoch;
      } catch (e) { return _OD.parse(str); }
    }
    dateParseOverride = stripConstruct(dateParseOverride); mask(dateParseOverride, "parse", 1);
    Object.defineProperty(DateOverride, "parse", { value: dateParseOverride, configurable: true, enumerable: false, writable: true });
    // 原型链/构造器引用/全局替换
    Object.setPrototypeOf(DateOverride, Function.prototype);
    _reg.set(DateOverride, "Date");
    _g.Date = DateOverride;
    Object.defineProperty(_OD.prototype, "constructor", { value: DateOverride, configurable: true, enumerable: false, writable: true });
    } catch (e) { /* 构造器域失败 → 原生 Date 保留 */ }

    // ---- Temporal.Now 五方法 (GeoSpoof temporal 移植) ----
    // 默认时区替换为 TZ; 显式传参时原样透传
    try {
      if (typeof Temporal !== "undefined" && Temporal && Temporal.Now) {
        var _Now = Temporal.Now;
        var _oPDT = _Now.plainDateTimeISO.bind(_Now);
        var _oPD = _Now.plainDateISO.bind(_Now);
        var _oPT = _Now.plainTimeISO.bind(_Now);
        var _oZDT = _Now.zonedDateTimeISO.bind(_Now);
        var _defs = [
          ["timeZoneId",       function () { return TZ; }],
          ["plainDateTimeISO", function (tzLike) { return tzLike === undefined ? _oPDT(TZ) : _oPDT(tzLike); }],
          ["plainDateISO",     function (tzLike) { return tzLike === undefined ? _oPD(TZ) : _oPD(tzLike); }],
          ["plainTimeISO",     function (tzLike) { return tzLike === undefined ? _oPT(TZ) : _oPT(tzLike); }],
          ["zonedDateTimeISO", function (tzLike) { return tzLike === undefined ? _oZDT(TZ) : _oZDT(tzLike); }]
        ];
        for (var di = 0; di < _defs.length; di++) {
          var dprop = _defs[di][0], dfn = _defs[di][1];
          dfn = stripConstruct(dfn); mask(dfn, dprop, 0);
          var dd = Object.getOwnPropertyDescriptor(_Now, dprop) || {};
          Object.defineProperty(_Now, dprop, {
            value: dfn,
            configurable: dd.configurable !== false,
            enumerable: !!dd.enumerable,
            writable: dd.writable !== false
          });
        }
      }
    } catch (e) { /* Temporal 覆盖失败 → 原生保留 */ }
})();
'''


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

    注意: 浏览器地理 (timezone/locale/经纬度) 已改由 geoip=True 按出口 IP 自动
    推导,不再从此处注入。本函数产出的字段现仅供行为层使用:
      - lat/lon      → Google Maps 城市级驻留 URL (与 geoip 同区域)
      - static_urls  → 信用净化白名单深访站点
      - lang_params  → Google 搜索 gl/hl (按 region 定"装成哪国人搜索")
      - locale/timezone → 保留字段 (地理已由 geoip 接管,此处仅作兜底/日志)

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
    # config['timezone'] 修 Worker (geoip 用 setdefault, 手动值优先);
    # 主线程 152 build 不吃 config -> 另用 add_init_script 注入 (见下)。
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
        # [主线程时区] 152 build 的 config 时区不作用于主文档 realm (实测 UTC),
        # 用引擎级 add_init_script 强改 Intl/Date (每页每 frame 主世界执行)。Worker 由 config 覆盖。
        if node_tz:
            try:
                browser.add_init_script(INIT_TZ_JS.replace("__TZ__", node_tz))
            except Exception as e:
                log("WARN 时区注入脚本失败: %s" % e)
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

        # --- 会话尾: 区域自检 (三核探测 + 漂移/送中落盘) ---
        probe = probe_region(page)
        region_verdict(node, region_code, probe)

        try:
            page.close()
        except Exception:
            pass

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
    """
    result = {"jump": "", "prem": "", "music": ""}
    try:
        page.goto("https://www.google.com/", wait_until="domcontentloaded")
        time.sleep(random.randint(2, 6))
        result["jump"] = urlparse(page.url).netloc
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
