#!/usr/bin/env python3
"""
tracker_analyzer.py  (v3)
--------------------------
Improvements over v2:
  • EasyPrivacy / disconnect.me blocklist  — 50,000+ rules vs hand-curated ~90
  • Scroll + click interaction simulation  — catches lazy-loaded / deferred trackers
  • Nested iframe scanning                 — recurses into all frames
  • Run diffing                            — compares to a previous JSON report
  • Consent banner bypass                  — auto-clicks "Accept all" for common CMPs

Usage:
    python tracker_analyzer.py <URL> [options]

Options:
    --output-dir  -o   Directory for reports  (default: .)
    --diff        -d   Path to a previous JSON report to diff against
    --no-accept        Skip consent banner auto-accept
    --no-interact      Skip scroll/click interaction simulation
    --no-blocklist     Skip EasyPrivacy / disconnect.me (use built-in sigs only)
    --timeout          Page load timeout in seconds  (default: 30)

Requirements:
    pip install playwright rich
    playwright install chromium
"""

import argparse
import csv
import json
import re
import sys
import time
from datetime import datetime
from pathlib import Path
from urllib.parse import urlparse

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1.  BUILT-IN TRACKER SIGNATURES  (fallback + named-tool detection)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

TRACKER_SIGNATURES = [
    # Analytics
    ("Google Analytics (GA4)",        "Analytics",       "url",       r"google-analytics\.com|gtag/js"),
    ("Google Tag Manager",            "Tag Manager",     "url",       r"googletagmanager\.com/gtm\.js"),
    ("Google Tag Manager",            "Tag Manager",     "js_global", r"\bwindow\.google_tag_manager\b"),
    ("Adobe Analytics",               "Analytics",       "url",       r"omtrdc\.net|2o7\.net|AppMeasurement\.js"),
    ("Adobe Analytics",               "Analytics",       "js_global", r"\bwindow\.s_gi\b|\bwindow\.AppMeasurement\b"),
    ("Matomo / Piwik",                "Analytics",       "url",       r"matomo\.js|piwik\.js"),
    ("Matomo / Piwik",                "Analytics",       "js_global", r"\bwindow\._paq\b"),
    ("Plausible",                     "Analytics",       "url",       r"plausible\.io/js/"),
    ("Fathom",                        "Analytics",       "url",       r"cdn\.usefathom\.com"),
    ("Heap Analytics",                "Analytics",       "url",       r"heapanalytics\.com"),
    ("Heap Analytics",                "Analytics",       "js_global", r"\bwindow\.heap\b"),
    ("Mixpanel",                      "Analytics",       "url",       r"cdn\.mxpnl\.com"),
    ("Mixpanel",                      "Analytics",       "js_global", r"\bwindow\.mixpanel\b"),
    ("Amplitude",                     "Analytics",       "url",       r"cdn\.amplitude\.com"),
    ("Amplitude",                     "Analytics",       "js_global", r"\bwindow\.amplitude\b"),
    ("Segment",                       "Analytics",       "url",       r"cdn\.segment\.com"),
    ("Woopra",                        "Analytics",       "url",       r"static\.woopra\.com"),
    ("Chartbeat",                     "Analytics",       "url",       r"static\.chartbeat\.com"),
    ("Clicky",                        "Analytics",       "url",       r"static\.getclicky\.com"),
    ("StatCounter",                   "Analytics",       "url",       r"statcounter\.com/counter"),
    ("Yandex Metrica",                "Analytics",       "url",       r"mc\.yandex\.ru|metrika\.yandex\.ru"),
    ("Yandex Metrica",                "Analytics",       "js_global", r"\bwindow\.ym\b"),
    # Advertising
    ("Meta Pixel",                    "Advertising",     "url",       r"connect\.facebook\.net|fbevents\.js"),
    ("Meta Pixel",                    "Advertising",     "js_global", r"\bwindow\.fbq\b"),
    ("Google Ads",                    "Advertising",     "url",       r"googleadservices\.com|pagead2\.googlesyndication\.com"),
    ("LinkedIn Insight Tag",          "Advertising",     "url",       r"snap\.licdn\.com"),
    ("LinkedIn Insight Tag",          "Advertising",     "js_global", r"\bwindow\._linkedin_data_partner_ids\b"),
    ("Twitter / X Pixel",             "Advertising",     "url",       r"static\.ads-twitter\.com"),
    ("Twitter / X Pixel",             "Advertising",     "js_global", r"\bwindow\.twq\b"),
    ("TikTok Pixel",                  "Advertising",     "url",       r"analytics\.tiktok\.com"),
    ("TikTok Pixel",                  "Advertising",     "js_global", r"\bwindow\.ttq\b"),
    ("Pinterest Tag",                 "Advertising",     "url",       r"s\.pinimg\.com/ct/"),
    ("Pinterest Tag",                 "Advertising",     "js_global", r"\bwindow\.pintrk\b"),
    ("Criteo",                        "Advertising",     "url",       r"static\.criteo\.net|dis\.criteo\.com"),
    ("Criteo",                        "Advertising",     "js_global", r"\bwindow\.criteo_q\b"),
    ("DoubleClick / DV360",           "Advertising",     "url",       r"doubleclick\.net"),
    ("AdRoll",                        "Advertising",     "url",       r"s\.adroll\.com"),
    ("Outbrain",                      "Advertising",     "url",       r"amplify\.outbrain\.com"),
    ("Taboola",                       "Advertising",     "url",       r"cdn\.taboola\.com"),
    ("Snap Pixel",                    "Advertising",     "url",       r"tr\.snapchat\.com"),
    ("Snap Pixel",                    "Advertising",     "js_global", r"\bwindow\.snaptr\b"),
    # Heatmaps / Session recording
    ("Hotjar",                        "Heatmap/Session", "url",       r"static\.hotjar\.com|script\.hotjar\.com"),
    ("Hotjar",                        "Heatmap/Session", "js_global", r"\bwindow\.hj\b|\bwindow\.hjBootstrap\b"),
    ("Microsoft Clarity",             "Heatmap/Session", "url",       r"clarity\.ms/tag"),
    ("Microsoft Clarity",             "Heatmap/Session", "js_global", r"\bwindow\.clarity\b"),
    ("FullStory",                     "Heatmap/Session", "url",       r"fullstory\.com/s/fs\.js|rs\.fullstory\.com"),
    ("FullStory",                     "Heatmap/Session", "js_global", r"\bwindow\.FS\b|\bwindow\._fs_debug\b"),
    ("Lucky Orange",                  "Heatmap/Session", "url",       r"luckyorange\.com"),
    ("Mouseflow",                     "Heatmap/Session", "url",       r"mouseflow\.com"),
    ("Smartlook",                     "Heatmap/Session", "url",       r"rec\.smartlook\.com"),
    ("LogRocket",                     "Heatmap/Session", "url",       r"cdn\.lr-ingest\.com"),
    ("LogRocket",                     "Heatmap/Session", "js_global", r"\bwindow\.LogRocket\b"),
    ("Inspectlet",                    "Heatmap/Session", "url",       r"cdn\.inspectlet\.com"),
    # A/B Testing
    ("Optimizely",                    "A/B Testing",     "url",       r"cdn\.optimizely\.com"),
    ("Optimizely",                    "A/B Testing",     "js_global", r"\bwindow\.optimizely\b"),
    ("VWO",                           "A/B Testing",     "url",       r"dev\.visualwebsiteoptimizer\.com"),
    ("VWO",                           "A/B Testing",     "js_global", r"\bwindow\.VWO\b|\bwindow\._vwo_code\b"),
    ("AB Tasty",                      "A/B Testing",     "url",       r"tags\.abtasty\.com"),
    ("Kameleoon",                     "A/B Testing",     "url",       r"kameleoon\.eu|kameleoon\.com"),
    # CRM / Customer engagement
    ("Intercom",                      "Customer Engage", "url",       r"widget\.intercom\.io|js\.intercomcdn\.com"),
    ("Intercom",                      "Customer Engage", "js_global", r"\bwindow\.Intercom\b"),
    ("HubSpot",                       "Customer Engage", "url",       r"js\.hs-scripts\.com|js\.hubspot\.com"),
    ("HubSpot",                       "Customer Engage", "js_global", r"\bwindow\._hsq\b"),
    ("Salesforce Pardot",             "Customer Engage", "url",       r"pi\.pardot\.com"),
    ("Drift",                         "Customer Engage", "url",       r"js\.driftt\.com"),
    ("Drift",                         "Customer Engage", "js_global", r"\bwindow\.drift\b"),
    ("Zendesk",                       "Customer Engage", "url",       r"static\.zdassets\.com"),
    ("Klaviyo",                       "Customer Engage", "url",       r"static\.klaviyo\.com"),
    ("Klaviyo",                       "Customer Engage", "js_global", r"\bwindow\._learnq\b"),
    ("Braze",                         "Customer Engage", "url",       r"js\.appboycdn\.com"),
    ("Braze",                         "Customer Engage", "js_global", r"\bwindow\.appboy\b|\bwindow\.braze\b"),
    # CMP
    ("OneTrust",                      "Consent (CMP)",   "url",       r"cdn\.cookielaw\.org|optanon\.blob\.core\.windows\.net"),
    ("OneTrust",                      "Consent (CMP)",   "js_global", r"\bwindow\.OneTrust\b|\bwindow\.OptanonWrapper\b"),
    ("Cookiebot",                     "Consent (CMP)",   "url",       r"consent\.cookiebot\.com"),
    ("Cookiebot",                     "Consent (CMP)",   "js_global", r"\bwindow\.Cookiebot\b"),
    ("Quantcast Choice",              "Consent (CMP)",   "url",       r"quantcast\.mgr\.consensu\.org"),
    ("TrustArc",                      "Consent (CMP)",   "url",       r"consent\.truste\.com"),
    ("Didomi",                        "Consent (CMP)",   "url",       r"sdk\.privacy-center\.org"),
    ("Didomi",                        "Consent (CMP)",   "js_global", r"\bwindow\.Didomi\b"),
    ("Usercentrics",                  "Consent (CMP)",   "url",       r"app\.usercentrics\.eu"),
    ("Iubenda",                       "Consent (CMP)",   "url",       r"cdn\.iubenda\.com"),
    # Performance / monitoring
    ("Cloudflare Insights",           "Performance",     "url",       r"static\.cloudflareinsights\.com"),
    ("New Relic",                     "Performance",     "url",       r"js-agent\.newrelic\.com"),
    ("New Relic",                     "Performance",     "js_global", r"\bwindow\.newrelic\b|\bwindow\.NREUM\b"),
    ("Datadog RUM",                   "Performance",     "url",       r"www\.datadoghq-browser-agent\.com"),
    ("Sentry",                        "Performance",     "url",       r"browser\.sentry-cdn\.com"),
    ("Sentry",                        "Performance",     "js_global", r"\bwindow\.__SENTRY__\b"),
]

COOKIE_SIGNATURES = [
    ("Google Analytics",    "Analytics",       r"^_ga$|^_gid$|^_gat$|^_ga_"),
    ("Google Ads",          "Advertising",     r"^_gcl_|^IDE$|^DSID$|^AID$"),
    ("Meta / Facebook",     "Advertising",     r"^_fbp$|^_fbc$|^fr$|^datr$|^sb$"),
    ("LinkedIn",            "Advertising",     r"^li_fat_id$|^UserMatchHistory$|^lidc$|^bcookie$"),
    ("Twitter / X",         "Advertising",     r"^_twitter_sess$|^twid$|^personalization_id$"),
    ("TikTok",              "Advertising",     r"^_ttp$|^ttwid$"),
    ("Pinterest",           "Advertising",     r"^_pinterest_ct_ua$|^_pinterest_sess$"),
    ("Hotjar",              "Heatmap/Session", r"^_hjid$|^_hjSession|^_hjAbsoluteSessionInProgress$"),
    ("Microsoft Clarity",   "Heatmap/Session", r"^_clck$|^_clsk$|^MUID$"),
    ("OneTrust",            "Consent (CMP)",   r"^OptanonConsent$|^OptanonAlertBoxClosed$"),
    ("Cookiebot",           "Consent (CMP)",   r"^CookieConsent$"),
    ("HubSpot",             "Customer Engage", r"^__hstc$|^hubspotutk$|^__hssc$|^__hssrc$"),
    ("Intercom",            "Customer Engage", r"^intercom-"),
    ("Mixpanel",            "Analytics",       r"^mp_"),
    ("Amplitude",           "Analytics",       r"^amplitude_id"),
    ("Segment",             "Analytics",       r"^ajs_"),
    ("Optimizely",          "A/B Testing",     r"^optimizelyEndUserId$|^optimizelyBuckets$"),
    ("VWO",                 "A/B Testing",     r"^_vwo_uuid|^_vis_opt_"),
    ("Criteo",              "Advertising",     r"^cto_bundle$|^cto_lwid$"),
    ("Yandex Metrica",      "Analytics",       r"^_ym_uid$|^_ym_d$"),
    ("Cloudflare",          "Performance",     r"^__cf_bm$|^_cf_clearance$"),
    ("Quantcast",           "Advertising",     r"^__qca$"),
    ("Taboola",             "Advertising",     r"^taboola_usg$|^t_gid$"),
    ("Drift",               "Customer Engage", r"^driftt_aid$"),
]

IFRAME_SIGNATURES = [
    ("Google Ads / DFP",       "Advertising",     r"doubleclick\.net|googlesyndication\.com"),
    ("Google Tag Manager",     "Tag Manager",     r"googletagmanager\.com/ns\.html"),
    ("Meta Pixel (noscript)",  "Advertising",     r"facebook\.com/tr\?"),
    ("LinkedIn (noscript)",    "Advertising",     r"linkedin\.com/px/"),
    ("Twitter / X",            "Advertising",     r"ads-twitter\.com|twitter\.com/i/adsct"),
    ("TikTok (noscript)",      "Advertising",     r"analytics\.tiktok\.com"),
    ("Snap (noscript)",        "Advertising",     r"tr\.snapchat\.com"),
    ("Pinterest (noscript)",   "Advertising",     r"ct\.pinterest\.com"),
    ("Criteo",                 "Advertising",     r"cat\.nl\.eu\.criteo\.com|dis\.criteo\.com"),
    ("Hotjar",                 "Heatmap/Session", r"vars\.hotjar\.com"),
    ("OneTrust",               "Consent (CMP)",   r"cdn\.cookielaw\.org"),
    ("Cookiebot",              "Consent (CMP)",   r"consent\.cookiebot\.com"),
    ("YouTube embed",          "Social/Media",    r"youtube\.com/embed|youtube-nocookie\.com"),
    ("Vimeo embed",            "Social/Media",    r"player\.vimeo\.com"),
    ("Spotify embed",          "Social/Media",    r"open\.spotify\.com/embed"),
    ("Google Maps embed",      "Social/Media",    r"maps\.google\.com|google\.com/maps/embed"),
    ("Recaptcha",              "Security",        r"google\.com/recaptcha"),
    ("hCaptcha",               "Security",        r"hcaptcha\.com"),
    ("Intercom",               "Customer Engage", r"widget\.intercom\.io"),
    ("Zendesk",                "Customer Engage", r"static\.zdassets\.com"),
]

CATEGORY_COLORS = {
    "Analytics":       "cyan",
    "Tag Manager":     "blue",
    "Advertising":     "red",
    "Heatmap/Session": "magenta",
    "A/B Testing":     "yellow",
    "Customer Engage": "green",
    "Consent (CMP)":   "bright_white",
    "Performance":     "bright_black",
    "Social/Media":    "bright_cyan",
    "Security":        "bright_green",
}

CATEGORY_HEX = {
    "Analytics":       "#22d3ee",
    "Tag Manager":     "#60a5fa",
    "Advertising":     "#f87171",
    "Heatmap/Session": "#e879f9",
    "A/B Testing":     "#fbbf24",
    "Customer Engage": "#4ade80",
    "Consent (CMP)":   "#e2e8f0",
    "Performance":     "#94a3b8",
    "Social/Media":    "#67e8f9",
    "Security":        "#86efac",
}

# Consent banner selectors (ordered by specificity)
CONSENT_ACCEPT_SELECTORS = [
    "#onetrust-accept-btn-handler",
    ".onetrust-accept-btn-handler",
    "#CybotCookiebotDialogBodyLevelButtonLevelOptinAllowAll",
    ".iubenda-cs-accept-btn",
    "#didomi-notice-agree-button",
    ".didomi-continue-without-agreeing",
    "[data-testid='uc-accept-all-button']",
    ".pdynamicbutton .call",
    ".qc-cmp2-summary-buttons button:last-child",
    "button[id*='accept-all']",
    "button[id*='acceptAll']",
    "button[id*='accept_all']",
    "button[class*='accept-all']",
    "button[class*='acceptAll']",
    "a[id*='accept-all']",
    "a[class*='accept-all']",
    "[aria-label*='Accept all' i]",
    "[aria-label*='Accetta tutto' i]",
    "[aria-label*='Tout accepter' i]",
    "[aria-label*='Alle akzeptieren' i]",
]

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2.  EASYPRIVACY / DISCONNECT.ME BLOCKLIST LOADER
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

BLOCKLIST_SOURCES = [
    (
        "EasyPrivacy",
        # Primary URL, no fallback needed — easylist.to is very stable
        ["https://easylist.to/easylist/easyprivacy.txt"],
        "adblock",
    ),
    (
        "disconnect.me",
        # Primary: GitHub raw (canonical repo, always up to date)
        # Fallback 1: services.disconnect.me direct endpoint
        # Fallback 2: Mozilla's mirrored copy (used by Firefox ETP)
        [
            "https://raw.githubusercontent.com/disconnectme/disconnect-tracking-protection/master/services.json",
            "https://services.disconnect.me/services.json",
            "https://raw.githubusercontent.com/mozilla-services/shavar-prod-lists/master/disconnect-blacklist.json",
        ],
        "disconnect",
    ),
]

_CACHE_DIR        = Path.home() / ".cache" / "tracker_analyzer"
_CACHE_MAX_AGE_H  = 24


def _cache_path(name: str) -> Path:
    _CACHE_DIR.mkdir(parents=True, exist_ok=True)
    return _CACHE_DIR / f"{name.replace(' ', '_').replace('.', '_')}.cache"


def _fetch_url(urls: list) -> tuple:
    """Try each URL in order, return (content, url_used) or (None, None)."""
    import urllib.request
    import urllib.error
    for url in urls:
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "tracker-analyzer/3.0"})
            with urllib.request.urlopen(req, timeout=15) as r:
                # Explicitly reject non-200 responses that urlopen may let through
                if r.status != 200:
                    print(f"  ⚠️   HTTP {r.status} from {url}", file=sys.stderr)
                    continue
                return r.read().decode("utf-8", errors="replace"), url
        except urllib.error.HTTPError as e:
            print(f"  ⚠️   HTTP {e.code} from {url} — trying next source …", file=sys.stderr)
        except urllib.error.URLError as e:
            print(f"  ⚠️   Network error for {url}: {e.reason} — trying next source …", file=sys.stderr)
        except Exception as e:
            print(f"  ⚠️   Could not fetch {url}: {e} — trying next source …", file=sys.stderr)
    return None, None


def _load_cached(name: str):
    p = _cache_path(name)
    if p.exists() and (time.time() - p.stat().st_mtime) / 3600 < _CACHE_MAX_AGE_H:
        return p.read_text(encoding="utf-8")
    return None


def _save_cache(name: str, content: str):
    _cache_path(name).write_text(content, encoding="utf-8")


def _parse_adblock(text: str) -> list:
    patterns = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith(("!", "##", "#@#", "@@", "[Adblock")):
            continue
        if "##" in line or "#@#" in line:
            continue
        rule = line.split("$")[0].strip()
        if not rule:
            continue
        if rule.startswith("||"):
            rule = rule[2:].rstrip("^")
            escaped = re.escape(rule).replace(r"\*", ".*")
            try:
                patterns.append(re.compile(escaped, re.IGNORECASE))
            except re.error:
                pass
        elif rule.startswith("|"):
            escaped = re.escape(rule[1:]).replace(r"\*", ".*")
            try:
                patterns.append(re.compile(escaped, re.IGNORECASE))
            except re.error:
                pass
        elif "*" in rule or "." in rule:
            escaped = re.escape(rule).replace(r"\*", ".*").replace(r"\^", r"[/?&]?")
            try:
                patterns.append(re.compile(escaped, re.IGNORECASE))
            except re.error:
                pass
    return patterns


def _parse_disconnect(text: str) -> list:
    patterns = []
    try:
        data = json.loads(text)
        for _cat, services in data.get("categories", {}).items():
            for service in services:
                for _name, domains_dict in service.items():
                    if isinstance(domains_dict, dict):
                        for domain in domains_dict.keys():
                            if domain and "." in domain:
                                try:
                                    patterns.append(re.compile(re.escape(domain), re.IGNORECASE))
                                except re.error:
                                    pass
    except (json.JSONDecodeError, AttributeError):
        pass
    return patterns


def load_blocklists(enabled: bool) -> tuple:
    meta = {"sources": [], "total_rules": 0, "from_cache": []}
    if not enabled:
        return [], meta

    print("  📥  Loading blocklists …", end=" ", flush=True)
    all_patterns = []

    for name, urls, fmt in BLOCKLIST_SOURCES:
        cached = _load_cached(name)
        if cached:
            content, url_used = cached, "(cache)"
            meta["from_cache"].append(name)
        else:
            content, url_used = _fetch_url(urls)
            if content:
                _save_cache(name, content)
            else:
                print(f"\n  ⚠️   Skipping {name} — all sources failed.", file=sys.stderr)
                continue

        patterns = _parse_adblock(content) if fmt == "adblock" else _parse_disconnect(content)
        if not patterns:
            print(f"\n  ⚠️   {name}: fetched content but parsed 0 rules (source may have changed format).", file=sys.stderr)
            continue

        all_patterns.extend(patterns)
        meta["sources"].append({"name": name, "rules": len(patterns), "url": url_used})
        meta["total_rules"] += len(patterns)

    cached_note = " (cached)" if meta["from_cache"] else " (fresh)"
    print(f"{meta['total_rules']:,} rules{cached_note}")
    return all_patterns, meta


def check_blocklist(url: str, patterns: list) -> bool:
    return any(p.search(url) for p in patterns)

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3.  ANALYSIS FUNCTIONS
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def compile_sigs(sigs):
    return [(n, c, t, re.compile(p, re.IGNORECASE)) for n, c, t, p in sigs]


def analyze_network(requests: list, compiled: list, blocklist: list) -> list:
    found = {}
    for req_url in requests:
        for name, category, mtype, rx in compiled:
            if mtype == "url" and rx.search(req_url) and name not in found:
                found[name] = {"name": name, "category": category,
                               "detected_via": "Network request",
                               "evidence": req_url[:120], "source": "built-in"}
    for req_url in requests:
        if check_blocklist(req_url, blocklist):
            hostname = urlparse(req_url).netloc or req_url[:60]
            key = f"[blocklist] {hostname}"
            if key not in found:
                found[key] = {"name": key, "category": "Advertising",
                              "detected_via": "Network request (blocklist)",
                              "evidence": req_url[:120], "source": "blocklist"}
    return list(found.values())


def analyze_js(js_content: str, compiled: list) -> list:
    found = {}
    for name, category, mtype, rx in compiled:
        if mtype == "js_global":
            m = rx.search(js_content)
            if m and name not in found:
                found[name] = {"name": name, "category": category,
                               "detected_via": "JS global / inline script",
                               "evidence": m.group(0)[:120], "source": "built-in"}
    return list(found.values())


def analyze_cookies(cookies: list) -> list:
    compiled = compile_sigs([(n, c, "cookie", p) for n, c, p in COOKIE_SIGNATURES])
    found = {}
    for cookie in cookies:
        cname = cookie.get("name", "")
        for name, category, _, rx in compiled:
            if rx.search(cname) and name not in found:
                found[name] = {
                    "name": name, "category": category,
                    "detected_via": "Cookie",
                    "evidence": f"{cname} (domain: {cookie.get('domain', '?')})",
                    "source": "built-in",
                    "cookie_details": {
                        "cookie_name": cname,
                        "domain":      cookie.get("domain", ""),
                        "httpOnly":    cookie.get("httpOnly", False),
                        "secure":      cookie.get("secure", False),
                        "sameSite":    cookie.get("sameSite", ""),
                        "expires":     cookie.get("expires", "session"),
                    },
                }
    return list(found.values())


def analyze_iframes(iframe_srcs: list, blocklist: list) -> list:
    compiled = compile_sigs([(n, c, "url", p) for n, c, p in IFRAME_SIGNATURES])
    found = {}
    for src in iframe_srcs:
        for name, category, _, rx in compiled:
            if rx.search(src) and name not in found:
                found[name] = {"name": name, "category": category,
                               "detected_via": "iframe / embed",
                               "evidence": src[:120], "source": "built-in"}
        if check_blocklist(src, blocklist):
            hostname = urlparse(src).netloc or src[:60]
            key = f"[blocklist] {hostname}"
            if key not in found:
                found[key] = {"name": key, "category": "Advertising",
                              "detected_via": "iframe / embed (blocklist)",
                              "evidence": src[:120], "source": "blocklist"}
    return list(found.values())


def merge_all(*hit_lists) -> list:
    merged = {}
    for hits in hit_lists:
        for hit in hits:
            key = hit["name"]
            if key not in merged:
                merged[key] = hit
            elif hit["detected_via"] not in merged[key]["detected_via"]:
                merged[key]["detected_via"] += " + " + hit["detected_via"]
    return sorted(merged.values(), key=lambda x: (x["category"], x["name"]))

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4.  BROWSER CRAWL  (interaction + nested iframes + consent bypass)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def _collect_frame_data(frame) -> tuple:
    """Recursively collect script sources and iframe srcs from a frame and its children."""
    js_chunks, iframe_srcs = [], []
    try:
        data = frame.evaluate("""() => {
            const js = [], iframes = [];
            document.querySelectorAll('script').forEach(s => {
                if (s.innerText) js.push(s.innerText.slice(0, 4000));
                if (s.src) js.push(s.src);
            });
            document.querySelectorAll('iframe, noscript').forEach(el => {
                const src = el.src || el.getAttribute('src') || '';
                if (src) iframes.push(src);
                if (el.tagName === 'NOSCRIPT') iframes.push(el.innerHTML || '');
            });
            js.push(Object.keys(window).join(' '));
            return { js, iframes };
        }""")
        js_chunks.extend(data.get("js", []))
        iframe_srcs.extend(data.get("iframes", []))
    except Exception:
        pass  # Cross-origin frames will throw — expected

    try:
        for child in frame.child_frames:
            cjs, ci = _collect_frame_data(child)
            js_chunks.extend(cjs)
            iframe_srcs.extend(ci)
    except Exception:
        pass

    return js_chunks, iframe_srcs


def _try_accept_consent(page, verbose: bool) -> bool:
    for selector in CONSENT_ACCEPT_SELECTORS:
        try:
            el = page.query_selector(selector)
            if el and el.is_visible():
                el.click()
                if verbose:
                    print(f"  ✅  Consent dismissed via: {selector}")
                page.wait_for_load_state("networkidle", timeout=5_000)
                return True
        except Exception:
            pass
    return False


def _simulate_interaction(page, verbose: bool):
    if verbose:
        print("  🖱️   Simulating scroll + interaction …")
    try:
        for pct in [25, 50, 75, 100]:
            page.evaluate(f"""() => {{
                window.scrollTo({{ top: document.body.scrollHeight * {pct} / 100,
                                   behavior: 'smooth' }});
            }}""")
            page.wait_for_timeout(800)
        vp = page.viewport_size or {"width": 1280, "height": 800}
        page.mouse.move(vp["width"] // 2, vp["height"] // 2)
        page.wait_for_timeout(400)
        try:
            page.wait_for_load_state("networkidle", timeout=6_000)
        except Exception:
            pass
    except Exception as e:
        if verbose:
            print(f"  ⚠️   Interaction error: {e}", file=sys.stderr)


def crawl(url: str, accept_consent: bool = True,
          interact: bool = True, timeout: int = 30,
          verbose: bool = True) -> dict:
    from playwright.sync_api import sync_playwright

    network_urls = []

    with sync_playwright() as p:
        browser = p.chromium.launch(headless=True)
        context = browser.new_context(
            user_agent=("Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
                        "AppleWebKit/537.36 (KHTML, like Gecko) "
                        "Chrome/124.0.0.0 Safari/537.36"),
            viewport={"width": 1280, "height": 800},
            locale="en-US",
        )
        page = context.new_page()
        page.on("request", lambda req: network_urls.append(req.url))
        page.goto(url, wait_until="networkidle", timeout=timeout * 1000)

        consent_accepted = False
        if accept_consent:
            consent_accepted = _try_accept_consent(page, verbose)
            if consent_accepted:
                page.wait_for_timeout(2000)

        if interact:
            _simulate_interaction(page, verbose)

        js_chunks, iframe_srcs = _collect_frame_data(page.main_frame)
        cookies = context.cookies()
        browser.close()

    return {
        "network_urls":     network_urls,
        "js_content":       " ".join(js_chunks),
        "cookies":          cookies,
        "iframe_srcs":      [s for s in iframe_srcs if s.strip()],
        "consent_accepted": consent_accepted,
        "interaction_done": interact,
    }

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5.  RUN DIFFING
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def diff_reports(current: list, previous_path: Path):
    try:
        prev  = json.loads(previous_path.read_text(encoding="utf-8"))
        prev_names = {t["name"] for t in prev.get("trackers", [])}
        curr_names = {t["name"] for t in current}
        return {
            "previous_scan": prev.get("scanned_at", "unknown"),
            "previous_file": str(previous_path),
            "added":         sorted(curr_names - prev_names),
            "removed":       sorted(prev_names - curr_names),
            "unchanged":     sorted(curr_names & prev_names),
        }
    except Exception as e:
        print(f"  ⚠️   Diff error: {e}", file=sys.stderr)
        return None

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6.  TERMINAL OUTPUT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def print_results(url, trackers, crawl_data, elapsed, diff, blocklist_meta):
    from rich.console import Console
    from rich.table import Table
    from rich import box
    from collections import Counter

    console = Console()
    console.print()
    console.print(f"[bold]🔍 Tracker Analysis[/bold]  [dim]{url}[/dim]")
    console.print(
        f"[dim]Scan completed in {elapsed:.1f}s — "
        f"{len(trackers)} tracker(s) | "
        f"{len(crawl_data['network_urls'])} requests | "
        f"{len(crawl_data['cookies'])} cookies | "
        f"{len(crawl_data['iframe_srcs'])} iframes[/dim]"
    )
    flags = []
    if crawl_data["consent_accepted"]: flags.append("[green]✓ consent bypassed[/green]")
    if crawl_data["interaction_done"]: flags.append("[green]✓ interaction simulated[/green]")
    if blocklist_meta["total_rules"]:
        cached = " (cached)" if blocklist_meta["from_cache"] else ""
        flags.append(f"[green]✓ blocklist {blocklist_meta['total_rules']:,} rules{cached}[/green]")
    if flags:
        console.print("[dim]  " + "  ·  ".join(flags) + "[/dim]")
    console.print()

    if not trackers:
        console.print("[green]✅  No known trackers detected.[/green]")
        return

    added_names = set(diff["added"]) if diff else set()

    table = Table(box=box.ROUNDED, show_header=True, header_style="bold")
    table.add_column("#",            style="dim", width=3)
    table.add_column("Tracker",      style="bold", min_width=28)
    table.add_column("Category",     min_width=16)
    table.add_column("Source",       width=9)
    table.add_column("Detected Via", min_width=30)
    table.add_column("Evidence",     style="dim", min_width=36)

    for i, t in enumerate(trackers, 1):
        color    = CATEGORY_COLORS.get(t["category"], "white")
        source   = "[dim]built-in[/dim]" if t.get("source") == "built-in" else "[yellow]blocklist[/yellow]"
        name_str = (f"[bold green]▲ {t['name']}[/bold green]"
                    if t["name"] in added_names else t["name"])
        table.add_row(str(i), name_str, f"[{color}]{t['category']}[/{color}]",
                      source, t["detected_via"], t["evidence"])

    console.print(table)

    cats = Counter(t["category"] for t in trackers)
    console.print("\n[bold]Category breakdown:[/bold]")
    for cat, count in sorted(cats.items()):
        console.print(f"  [{CATEGORY_COLORS.get(cat,'white')}]●[/{CATEGORY_COLORS.get(cat,'white')}]  {cat}: {count}")

    if diff:
        console.print(f"\n[bold]Diff vs {diff['previous_scan']}:[/bold]")
        if diff["added"]:
            console.print(f"  [green]▲ New:[/green]     {', '.join(diff['added'])}")
        if diff["removed"]:
            console.print(f"  [red]▼ Removed:[/red]  {', '.join(diff['removed'])}")
        if not diff["added"] and not diff["removed"]:
            console.print("  [dim]No changes since last scan.[/dim]")
    console.print()

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7.  FILE OUTPUT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def save_json(path, data):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)


def save_csv(path, trackers):
    if not trackers:
        return
    with open(path, "w", newline="", encoding="utf-8") as f:
        w = csv.DictWriter(f, fieldnames=["name","category","detected_via","evidence","source"],
                           extrasaction="ignore")
        w.writeheader()
        w.writerows(trackers)


def save_html(path, url, trackers, crawl_data, elapsed, ts_str, diff, blocklist_meta):
    from collections import Counter

    domain      = urlparse(url).netloc
    cats        = Counter(t["category"] for t in trackers)
    added_names = set(diff["added"]) if diff else set()

    CAT_STYLE = {
        "Analytics":       ("#E6F1FB", "#B5D4F4", "#0C447C"),
        "Tag Manager":     ("#EAF3DE", "#C0DD97", "#3B6D11"),
        "Advertising":     ("#FCEBEB", "#F7C1C1", "#A32D2D"),
        "Heatmap/Session": ("#FBEAF0", "#F4C0D1", "#72243E"),
        "A/B Testing":     ("#FAEEDA", "#FAC775", "#854F0B"),
        "Customer Engage": ("#E1F5EE", "#9FE1CB", "#085041"),
        "Consent (CMP)":   ("#F1EFE8", "#D3D1C7", "#444441"),
        "Performance":     ("#F1EFE8", "#D3D1C7", "#444441"),
        "Social/Media":    ("#E6F1FB", "#B5D4F4", "#0C447C"),
        "Security":        ("#EAF3DE", "#C0DD97", "#3B6D11"),
    }
    BAR_COLOR = {
        "Analytics":       "#378ADD",
        "Tag Manager":     "#639922",
        "Advertising":     "#E24B4A",
        "Heatmap/Session": "#D4537E",
        "A/B Testing":     "#BA7517",
        "Customer Engage": "#1D9E75",
        "Consent (CMP)":   "#888780",
        "Performance":     "#888780",
        "Social/Media":    "#378ADD",
        "Security":        "#639922",
    }

    def cat_pill(category):
        bg, bd, tx = CAT_STYLE.get(category, ("#F1EFE8", "#D3D1C7", "#444441"))
        return (f'<span style="display:inline-block;font-size:10px;padding:2px 7px;'
                f'border-radius:3px;border:0.5px solid {bd};background:{bg};'
                f'color:{tx};font-weight:500;white-space:nowrap">{category}</span>')

    def src_label(source):
        if source == "blocklist":
            return '<span style="font-size:11px;color:#BA7517">blocklist</span>'
        return '<span style="font-size:11px;color:#888">built-in</span>'

    def tracker_rows():
        rows = []
        for i, t in enumerate(trackers, 1):
            via = t["detected_via"].replace(" + ", " · ")
            new_mk = (' <span style="font-size:10px;padding:1px 6px;border-radius:3px;'
                      'background:#EAF3DE;color:#3B6D11;border:0.5px solid #C0DD97">new</span>'
                      if t["name"] in added_names else "")
            ev = t["evidence"][:100]
            rows.append(
                f'<tr class="trow" data-cat="{t["category"]}">' +
                f'<td class="td-n">{i}</td>' +
                f'<td class="td-name">{t["name"]}{new_mk}</td>' +
                f'<td class="td-cat">{cat_pill(t["category"])}</td>' +
                f'<td class="td-src">{src_label(t.get("source","built-in"))}</td>' +
                f'<td class="td-via">{via}</td>' +
                f'<td class="td-ev">{ev}</td>' +
                f'</tr>'
            )
        return "\n".join(rows)

    def cookie_rows():
        rows = []
        for i, c in enumerate(crawl_data["cookies"], 1):
            ho  = "✓" if c.get("httpOnly") else "✗"
            sec = "✓" if c.get("secure")   else "✗"
            ho_col  = "#3B6D11" if c.get("httpOnly") else "#A32D2D"
            sec_col = "#3B6D11" if c.get("secure")   else "#A32D2D"
            exp = c.get("expires")
            try:
                exp_str = datetime.fromtimestamp(float(exp)).strftime("%Y-%m-%d") if exp and float(exp) > 0 else "Session"
            except Exception:
                exp_str = "Session"
            rows.append(
                f'<tr>' +
                f'<td class="td-n">{i}</td>' +
                f'<td class="td-mono">{c.get("name","")}</td>' +
                f'<td class="td-mono" style="color:#666">{c.get("domain","")}</td>' +
                f'<td class="td-ctr" style="color:{ho_col}">{ho}</td>' +
                f'<td class="td-ctr" style="color:{sec_col}">{sec}</td>' +
                f'<td>{c.get("sameSite") or "—"}</td>' +
                f'<td class="td-mono" style="color:#666">{exp_str}</td>' +
                f'</tr>'
            )
        return "\n".join(rows)

    def iframe_rows():
        return "\n".join(
            f'<tr><td class="td-n">{i}</td><td class="td-ev">{s[:140]}</td></tr>'
            for i, s in enumerate(crawl_data["iframe_srcs"], 1)
        )

    max_count = max(cats.values()) if cats else 1
    bar_rows = []
    for cat, count in sorted(cats.items(), key=lambda x: -x[1]):
        pct = round(count / max_count * 100)
        color = BAR_COLOR.get(cat, "#888780")
        bar_rows.append(
            f'<div class="bar-row">' +
            f'<div class="bar-label">{cat}</div>' +
            f'<div class="bar-track"><div class="bar-fill" style="width:{pct}%;background:{color}"></div></div>' +
            f'<div class="bar-count">{count}</div>' +
            f'</div>'
        )
    bars_html = "\n".join(bar_rows)

    def diff_html():
        if not diff:
            return ""
        prev_ts = diff["previous_scan"]
        added_items = "".join(
            f'<div class="diff-item" style="color:#3B6D11"><span style="font-size:10px;margin-right:4px">+</span>{n}</div>'
            for n in diff["added"]
        ) or '<div style="font-size:12px;color:#999;font-style:italic">None</div>'
        removed_items = "".join(
            f'<div class="diff-item" style="color:#A32D2D"><span style="font-size:10px;margin-right:4px">-</span>{n}</div>'
            for n in diff["removed"]
        ) or '<div style="font-size:12px;color:#999;font-style:italic">None</div>'
        return (
            '<div class="diff-strip">'
            f'<div class="diff-cell"><div class="diff-title" style="color:#3B6D11">+ new since {prev_ts}</div>{added_items}</div>'
            f'<div class="diff-cell" style="border-left:0.5px solid #ddd"><div class="diff-title" style="color:#A32D2D">- removed since {prev_ts}</div>{removed_items}</div>'
            '</div>'
        )

    filter_btns = ['<button class="fbt active" data-cat="all">All</button>']
    for cat in sorted(set(t["category"] for t in trackers)):
        _, bd, tx = CAT_STYLE.get(cat, ("#F1EFE8", "#D3D1C7", "#444441"))
        filter_btns.append(
            f'<button class="fbt" data-cat="{cat}" data-bd="{bd}" data-tx="{tx}">{cat}</button>'
        )
    filter_btns_html = "\n".join(filter_btns)

    def flag(label, active):
        if active:
            return (f'<span style="font-size:10px;padding:2px 8px;border-radius:3px;'
                    f'border:0.5px solid #C0DD97;background:#EAF3DE;color:#3B6D11">{label}</span>')
        return (f'<span style="font-size:10px;padding:2px 8px;border-radius:3px;'
                f'border:0.5px solid #ddd;color:#999">{label}</span>')

    bl_label = f'blocklist {blocklist_meta["total_rules"]:,} rules'
    if blocklist_meta["from_cache"]:
        bl_label += " (cached)"
    flags_html = " ".join([
        flag("consent bypass",  crawl_data["consent_accepted"]),
        flag("interaction sim", crawl_data["interaction_done"]),
        flag(bl_label,          bool(blocklist_meta["total_rules"])),
        flag("diff",            bool(diff)),
    ])

    bl_note = ""
    if blocklist_meta["total_rules"]:
        srcs = " + ".join(s["name"] for s in blocklist_meta["sources"])
        bl_note = f" · {blocklist_meta['total_rules']:,} rules ({srcs})"
        if blocklist_meta["from_cache"]:
            bl_note += " cached"

    empty_row_t = '<tr><td colspan="6" class="empty-cell">No trackers detected.</td></tr>'
    empty_row_c = '<tr><td colspan="7" class="empty-cell">No cookies captured.</td></tr>'
    empty_row_i = '<tr><td colspan="2" class="empty-cell">No iframes found.</td></tr>'

    html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8"/>
<meta name="viewport" content="width=device-width,initial-scale=1"/>
<title>Tracker report — {domain}</title>
<style>
*,*::before,*::after{{box-sizing:border-box;margin:0;padding:0}}
html{{font-size:14px;-webkit-font-smoothing:antialiased}}
body{{font-family:ui-monospace,'Cascadia Code','SF Mono',Menlo,Consolas,monospace;background:#f5f4f0;color:#1a1a1a;min-height:100vh;line-height:1.5}}
a{{color:inherit;text-decoration:none}}
a:hover{{text-decoration:underline}}
.page-header{{background:#fff;border-bottom:0.5px solid #ddd;padding:20px 32px;display:flex;justify-content:space-between;align-items:flex-start;gap:24px}}
.ph-left{{min-width:0}}
.ph-domain{{font-size:15px;font-weight:500;letter-spacing:-0.02em;color:#1a1a1a}}
.ph-url{{font-size:11px;color:#888;margin-top:3px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.ph-right{{text-align:right;flex-shrink:0}}
.ph-meta{{font-size:11px;color:#888;line-height:1.9}}
.ph-flags{{display:flex;gap:5px;margin-top:6px;justify-content:flex-end;flex-wrap:wrap}}
.hero{{background:#fff;border-bottom:0.5px solid #ddd;padding:24px 32px;display:flex;align-items:flex-end;gap:48px}}
.hero-count{{flex-shrink:0}}
.hero-num{{font-size:72px;font-weight:500;line-height:1;letter-spacing:-0.04em;color:#1a1a1a}}
.hero-label{{font-size:10px;text-transform:uppercase;letter-spacing:0.1em;color:#888;margin-top:4px}}
.hero-bars{{flex:1;display:flex;flex-direction:column;gap:8px;padding-bottom:4px}}
.bar-row{{display:flex;align-items:center;gap:10px}}
.bar-label{{font-size:11px;color:#666;width:120px;flex-shrink:0;text-align:right}}
.bar-track{{flex:1;height:5px;background:#eee;border-radius:1px;overflow:hidden}}
.bar-fill{{height:100%;border-radius:1px}}
.bar-count{{font-size:11px;color:#888;width:20px;text-align:right}}
.stat-row{{display:grid;grid-template-columns:repeat(3,1fr);border-bottom:0.5px solid #ddd}}
.stat-cell{{background:#fff;padding:12px 24px;border-right:0.5px solid #ddd}}
.stat-cell:last-child{{border-right:none}}
.stat-n{{font-size:22px;font-weight:500;color:#1a1a1a;letter-spacing:-0.02em}}
.stat-l{{font-size:10px;text-transform:uppercase;letter-spacing:0.08em;color:#888;margin-top:1px}}
.diff-strip{{display:flex;background:#fff;border-bottom:0.5px solid #ddd}}
.diff-cell{{flex:1;padding:16px 32px}}
.diff-title{{font-size:10px;text-transform:uppercase;letter-spacing:0.08em;font-weight:500;margin-bottom:10px}}
.diff-item{{font-size:12px;padding:4px 0;border-bottom:0.5px solid #eee;display:flex;align-items:center}}
.diff-item:last-child{{border-bottom:none}}
.section-bar{{background:#f5f4f0;padding:8px 32px;font-size:10px;text-transform:uppercase;letter-spacing:0.1em;color:#888;border-bottom:0.5px solid #ddd;border-top:0.5px solid #ddd;margin-top:24px}}
.section-bar:first-of-type{{margin-top:0}}
.filter-bar{{background:#fff;padding:12px 32px;border-bottom:0.5px solid #ddd;display:flex;gap:6px;flex-wrap:wrap}}
.fbt{{font-family:inherit;font-size:11px;padding:3px 10px;border-radius:3px;border:0.5px solid #ccc;background:#fff;color:#444;cursor:pointer;transition:all .12s}}
.fbt:hover{{border-color:#999;color:#1a1a1a}}
.fbt.active{{background:#1a1a1a;border-color:#1a1a1a;color:#fff}}
.table-wrap{{overflow-x:auto;background:#fff}}
table{{width:100%;border-collapse:collapse;font-size:12px}}
thead th{{font-size:10px;text-transform:uppercase;letter-spacing:0.08em;color:#888;font-weight:500;padding:8px 12px;text-align:left;background:#fafaf8;border-bottom:0.5px solid #ddd;white-space:nowrap}}
tbody tr{{border-bottom:0.5px solid #eee}}
tbody tr:last-child{{border-bottom:none}}
tbody tr:hover td{{background:#fafaf8}}
td{{padding:8px 12px;vertical-align:middle;color:#1a1a1a}}
.td-n{{color:#bbb;width:32px;font-size:11px}}
.td-name{{font-weight:500;font-size:12px}}
.td-cat{{white-space:nowrap}}
.td-src{{white-space:nowrap}}
.td-via{{font-size:11px;color:#666}}
.td-ev{{font-size:10px;color:#999;max-width:260px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}}
.td-mono{{font-size:11px}}
.td-ctr{{text-align:center;font-weight:500}}
.empty-cell{{padding:32px;text-align:center;color:#bbb;font-size:12px;font-style:italic}}
.page-footer{{padding:14px 32px;font-size:10px;color:#bbb;display:flex;justify-content:space-between;margin-top:24px;border-top:0.5px solid #ddd;background:#fff}}
</style>
</head>
<body>
<div class="page-header">
  <div class="ph-left">
    <div class="ph-domain">{domain}</div>
    <div class="ph-url"><a href="{url}" target="_blank" rel="noopener">{url}</a></div>
  </div>
  <div class="ph-right">
    <div class="ph-meta">{ts_str} &nbsp;·&nbsp; {elapsed:.1f}s &nbsp;·&nbsp; {len(crawl_data['network_urls'])} requests</div>
    <div class="ph-flags">{flags_html}</div>
  </div>
</div>
<div class="hero">
  <div class="hero-count">
    <div class="hero-num">{len(trackers)}</div>
    <div class="hero-label">trackers detected</div>
  </div>
  <div class="hero-bars">{bars_html}</div>
</div>
<div class="stat-row">
  <div class="stat-cell"><div class="stat-n">{len(crawl_data['cookies'])}</div><div class="stat-l">Cookies</div></div>
  <div class="stat-cell"><div class="stat-n">{len(crawl_data['iframe_srcs'])}</div><div class="stat-l">Iframes</div></div>
  <div class="stat-cell"><div class="stat-n">{len(cats)}</div><div class="stat-l">Categories</div></div>
</div>
{diff_html()}
<div class="section-bar">Trackers — {len(trackers)} total</div>
<div class="filter-bar">{filter_btns_html}</div>
<div class="table-wrap">
  <table>
    <thead><tr><th>#</th><th>Tracker</th><th>Category</th><th>Source</th><th>Detected via</th><th>Evidence</th></tr></thead>
    <tbody>{tracker_rows() if trackers else empty_row_t}</tbody>
  </table>
</div>
<div class="section-bar">Cookies — {len(crawl_data['cookies'])} total</div>
<div class="table-wrap">
  <table>
    <thead><tr><th>#</th><th>Name</th><th>Domain</th><th>HttpOnly</th><th>Secure</th><th>SameSite</th><th>Expires</th></tr></thead>
    <tbody>{cookie_rows() if crawl_data['cookies'] else empty_row_c}</tbody>
  </table>
</div>
<div class="section-bar">Iframes &amp; embeds — {len(crawl_data['iframe_srcs'])} total</div>
<div class="table-wrap">
  <table>
    <thead><tr><th>#</th><th>Source / content</th></tr></thead>
    <tbody>{iframe_rows() if crawl_data['iframe_srcs'] else empty_row_i}</tbody>
  </table>
</div>
<div class="page-footer">
  <span>tracker_analyzer.py v3{bl_note}</span>
  <span>{ts_str}</span>
</div>
<script>
document.querySelectorAll('.fbt').forEach(btn => {{
  btn.addEventListener('click', function() {{
    document.querySelectorAll('.fbt').forEach(b => b.classList.remove('active'));
    this.classList.add('active');
    const cat = this.dataset.cat;
    document.querySelectorAll('.trow').forEach(row => {{
      row.style.display = (cat === 'all' || row.dataset.cat === cat) ? '' : 'none';
    }});
  }});
}});
</script>
</body>
</html>"""

    with open(path, "w", encoding="utf-8") as f:
        f.write(html)


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8.  ENTRY POINT
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

def main():
    parser = argparse.ArgumentParser(
        description="Analyze a website for tracker tools — v3 (blocklist + interaction + diff)"
    )
    parser.add_argument("url")
    parser.add_argument("--output-dir", "-o", default=".")
    parser.add_argument("--diff",        "-d", metavar="PREV_JSON",
                        help="Previous JSON report to diff against")
    parser.add_argument("--no-accept",    action="store_true", help="Skip consent banner bypass")
    parser.add_argument("--no-interact",  action="store_true", help="Skip scroll/click simulation")
    parser.add_argument("--no-blocklist", action="store_true", help="Skip EasyPrivacy/disconnect.me")
    parser.add_argument("--timeout",      type=int, default=30)
    args = parser.parse_args()

    url = args.url
    if not url.startswith(("http://", "https://")):
        url = "https://" + url

    output_dir = Path(args.output_dir)
    output_dir.mkdir(parents=True, exist_ok=True)

    domain  = urlparse(url).netloc.replace("www.", "").replace(".", "_")
    now     = datetime.now()
    ts      = now.strftime("%Y%m%d_%H%M%S")
    ts_str  = now.strftime("%Y-%m-%d %H:%M:%S")
    base    = f"trackers_{domain}_{ts}"

    print(f"\n🔍  tracker_analyzer.py v3")
    print(f"🌐  Target: {url}\n")

    blocklist_patterns, blocklist_meta = load_blocklists(not args.no_blocklist)

    print("🚀  Launching browser …")
    t0 = time.time()
    try:
        crawl_data = crawl(url,
                           accept_consent = not args.no_accept,
                           interact       = not args.no_interact,
                           timeout        = args.timeout,
                           verbose        = True)
    except Exception as e:
        print(f"\n❌  Failed to load page: {e}", file=sys.stderr)
        sys.exit(1)
    elapsed = time.time() - t0

    compiled    = compile_sigs(TRACKER_SIGNATURES)
    url_hits    = analyze_network(crawl_data["network_urls"], compiled, blocklist_patterns)
    js_hits     = analyze_js(crawl_data["js_content"], compiled)
    cookie_hits = analyze_cookies(crawl_data["cookies"])
    iframe_hits = analyze_iframes(crawl_data["iframe_srcs"], blocklist_patterns)
    trackers    = merge_all(url_hits, js_hits, cookie_hits, iframe_hits)

    diff = diff_reports(trackers, Path(args.diff)) if args.diff else None

    print_results(url, trackers, crawl_data, elapsed, diff, blocklist_meta)

    report = {
        "url":                    url,
        "scanned_at":             ts_str,
        "elapsed_seconds":        round(elapsed, 2),
        "total_network_requests": len(crawl_data["network_urls"]),
        "total_cookies":          len(crawl_data["cookies"]),
        "total_iframes":          len(crawl_data["iframe_srcs"]),
        "trackers_found":         len(trackers),
        "consent_accepted":       crawl_data["consent_accepted"],
        "interaction_simulated":  crawl_data["interaction_done"],
        "blocklist":              blocklist_meta,
        "trackers":               trackers,
        "all_cookies":            crawl_data["cookies"],
        "all_iframes":            crawl_data["iframe_srcs"],
        "diff":                   diff,
    }

    json_path = output_dir / f"{base}.json"
    csv_path  = output_dir / f"{base}.csv"
    html_path = output_dir / f"{base}.html"

    save_json(json_path, report)
    save_csv(csv_path, trackers)
    save_html(html_path, url, trackers, crawl_data, elapsed, ts_str, diff, blocklist_meta)

    print(f"📄  JSON → {json_path}")
    print(f"📊  CSV  → {csv_path}")
    print(f"🌐  HTML → {html_path}\n")


if __name__ == "__main__":
    main()
