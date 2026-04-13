#!/usr/bin/env python3
"""
nmap_vulners_report.py
Parse Nmap XML output (with the vulners NSE script) and produce a
professional self-contained HTML report.

Usage:
    nmap -sV --script vulners -oX scan.xml <target>
    python3 nmap_vulners_report.py scan.xml -o report.html
    python3 nmap_vulners_report.py scan.xml              # writes report.html next to scan.xml
"""

import argparse
import html
import json
import re
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional


# ---------------------------------------------------------------------------
# Data model
# ---------------------------------------------------------------------------

CVSS_CRITICAL = 9.0
CVSS_HIGH     = 7.0
CVSS_MEDIUM   = 4.0
CVSS_LOW      = 0.1

@dataclass
class Vuln:
    cve_id:  str
    cvss:    float
    type:    str          # e.g. "CVE"
    is_exploit: bool

@dataclass
class Port:
    number:   int
    protocol: str
    state:    str
    service:  str
    product:  str
    version:  str
    extra:    str
    cpe:      list[str]   = field(default_factory=list)
    vulns:    list[Vuln]  = field(default_factory=list)

@dataclass
class Host:
    address:  str
    hostname: str
    status:   str
    os_hint:  str
    ports:    list[Port] = field(default_factory=list)

@dataclass
class ScanMeta:
    scanner:    str
    args:       str
    start_ts:   str
    end_ts:     str
    elapsed:    str
    hosts_up:   int
    hosts_down: int


# ---------------------------------------------------------------------------
# Parser
# ---------------------------------------------------------------------------

def _cvss(s: str) -> float:
    try:
        return float(s)
    except (ValueError, TypeError):
        return 0.0


def parse_xml(path: Path) -> tuple[ScanMeta, list[Host]]:
    tree = ET.parse(path)
    root = tree.getroot()

    # --- meta ---
    start = int(root.get("start", "0"))
    run_stats = root.find("runstats")
    finished = run_stats.find("finished") if run_stats is not None else None
    hosts_el  = run_stats.find("hosts")   if run_stats is not None else None

    meta = ScanMeta(
        scanner   = root.get("scanner", "nmap"),
        args      = root.get("args", ""),
        start_ts  = datetime.fromtimestamp(start, tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
                    if start else "–",
        end_ts    = datetime.fromtimestamp(int(finished.get("time", "0")), tz=timezone.utc)
                    .strftime("%Y-%m-%d %H:%M UTC")
                    if finished is not None else "–",
        elapsed   = finished.get("elapsed", "–") + "s" if finished is not None else "–",
        hosts_up  = int(hosts_el.get("up",   "0")) if hosts_el is not None else 0,
        hosts_down= int(hosts_el.get("down", "0")) if hosts_el is not None else 0,
    )

    hosts: list[Host] = []

    for host_el in root.findall("host"):
        status_el = host_el.find("status")
        status = status_el.get("state", "unknown") if status_el is not None else "unknown"

        # address
        addr = "unknown"
        for addr_el in host_el.findall("address"):
            if addr_el.get("addrtype") in ("ipv4", "ipv6"):
                addr = addr_el.get("addr", "unknown")
                break

        # hostname
        hn = ""
        hostnames_el = host_el.find("hostnames")
        if hostnames_el is not None:
            hn_el = hostnames_el.find("hostname")
            if hn_el is not None:
                hn = hn_el.get("name", "")

        # OS hint from osmatch
        os_hint = ""
        os_el = host_el.find("os")
        if os_el is not None:
            om = os_el.find("osmatch")
            if om is not None:
                os_hint = om.get("name", "")

        host = Host(address=addr, hostname=hn, status=status, os_hint=os_hint)

        ports_el = host_el.find("ports")
        if ports_el is not None:
            for port_el in ports_el.findall("port"):
                state_el   = port_el.find("state")
                service_el = port_el.find("service")

                port = Port(
                    number   = int(port_el.get("portid", "0")),
                    protocol = port_el.get("protocol", "tcp"),
                    state    = state_el.get("state", "unknown") if state_el is not None else "unknown",
                    service  = service_el.get("name",    "") if service_el is not None else "",
                    product  = service_el.get("product", "") if service_el is not None else "",
                    version  = service_el.get("version", "") if service_el is not None else "",
                    extra    = service_el.get("extrainfo", "") if service_el is not None else "",
                )

                # CPE
                if service_el is not None:
                    for cpe_el in service_el.findall("cpe"):
                        if cpe_el.text:
                            port.cpe.append(cpe_el.text.strip())

                # vulners script output
                for script_el in port_el.findall("script"):
                    if script_el.get("id") != "vulners":
                        continue
                    # iterate <table key="..."> inside vulners output
                    for cpe_table in script_el.findall("table"):
                        for vuln_table in cpe_table.findall("table"):
                            v_data: dict[str, str] = {}
                            for elem in vuln_table.findall("elem"):
                                k = elem.get("key", "")
                                v = elem.text or ""
                                v_data[k] = v.strip()
                            if "id" in v_data and "cvss" in v_data:
                                port.vulns.append(Vuln(
                                    cve_id     = v_data["id"],
                                    cvss       = _cvss(v_data["cvss"]),
                                    type       = v_data.get("type", "CVE"),
                                    is_exploit = v_data.get("is_exploit", "false").lower() == "true",
                                ))

                host.ports.append(port)

        hosts.append(host)

    return meta, hosts


# ---------------------------------------------------------------------------
# Severity helpers
# ---------------------------------------------------------------------------

def severity_label(cvss: float) -> str:
    if cvss >= CVSS_CRITICAL: return "CRITICAL"
    if cvss >= CVSS_HIGH:     return "HIGH"
    if cvss >= CVSS_MEDIUM:   return "MEDIUM"
    if cvss >= CVSS_LOW:      return "LOW"
    return "INFO"

def severity_class(cvss: float) -> str:
    return {
        "CRITICAL": "sev-critical",
        "HIGH":     "sev-high",
        "MEDIUM":   "sev-medium",
        "LOW":      "sev-low",
        "INFO":     "sev-info",
    }[severity_label(cvss)]

def host_max_cvss(host: Host) -> float:
    return max((v.cvss for p in host.ports for v in p.vulns), default=0.0)

def port_max_cvss(port: Port) -> float:
    return max((v.cvss for v in port.vulns), default=0.0)


# ---------------------------------------------------------------------------
# HTML generation
# ---------------------------------------------------------------------------

CSS = """
:root {
  --bg:        #f7f8fa;
  --surface:   #ffffff;
  --border:    #e2e5ea;
  --text:      #1a1d23;
  --muted:     #6b7280;
  --accent:    #1a56db;

  --c-critical:#7f1d1d;
  --bg-critical:#fef2f2;
  --bd-critical:#fca5a5;

  --c-high:   #78350f;
  --bg-high:  #fffbeb;
  --bd-high:  #fcd34d;

  --c-medium: #713f12;
  --bg-medium:#fefce8;
  --bd-medium:#fde68a;

  --c-low:    #14532d;
  --bg-low:   #f0fdf4;
  --bd-low:   #86efac;

  --c-info:   #1e3a5f;
  --bg-info:  #eff6ff;
  --bd-info:  #93c5fd;

  --mono: 'JetBrains Mono', 'Fira Mono', 'Cascadia Code', monospace;
  --sans: 'Inter', 'DM Sans', system-ui, sans-serif;
}

*, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

body {
  font-family: var(--sans);
  background: var(--bg);
  color: var(--text);
  font-size: 14px;
  line-height: 1.6;
}

a { color: var(--accent); text-decoration: none; }
a:hover { text-decoration: underline; }

/* ── Layout ─────────────────────────────────── */
.page { max-width: 1100px; margin: 0 auto; padding: 2rem 1.5rem 4rem; }

/* ── Header ─────────────────────────────────── */
.report-header {
  display: flex; align-items: flex-start; justify-content: space-between;
  padding: 2rem 2.5rem;
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 12px;
  margin-bottom: 1.5rem;
}
.report-title { font-size: 22px; font-weight: 700; letter-spacing: -0.3px; margin-bottom: 4px; }
.report-subtitle { color: var(--muted); font-size: 13px; }
.report-meta-grid {
  display: grid; grid-template-columns: repeat(3, auto); gap: 0.25rem 2rem;
  text-align: right; font-size: 12px;
}
.report-meta-grid .label { color: var(--muted); }
.report-meta-grid .value { font-family: var(--mono); font-size: 11px; color: var(--text); }

/* ── Summary cards ──────────────────────────── */
.summary-row {
  display: grid;
  grid-template-columns: repeat(auto-fit, minmax(130px, 1fr));
  gap: 12px;
  margin-bottom: 1.5rem;
}
.stat-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  padding: 1rem 1.25rem;
}
.stat-card .num  { font-size: 28px; font-weight: 700; line-height: 1; margin-bottom: 4px; }
.stat-card .lbl  { font-size: 11px; color: var(--muted); text-transform: uppercase; letter-spacing: .05em; }
.stat-card.critical .num { color: #dc2626; }
.stat-card.high     .num { color: #d97706; }
.stat-card.medium   .num { color: #ca8a04; }
.stat-card.low      .num { color: #16a34a; }

/* ── Section heading ────────────────────────── */
.section-title {
  font-size: 13px; font-weight: 600;
  text-transform: uppercase; letter-spacing: .07em;
  color: var(--muted);
  margin: 2rem 0 .75rem;
}

/* ── Host card ──────────────────────────────── */
.host-card {
  background: var(--surface);
  border: 1px solid var(--border);
  border-radius: 10px;
  margin-bottom: 1rem;
  overflow: hidden;
}
.host-header {
  display: flex; align-items: center; gap: 1rem;
  padding: .85rem 1.25rem;
  cursor: pointer;
  user-select: none;
  border-bottom: 1px solid transparent;
  transition: background .15s;
}
.host-header:hover { background: var(--bg); }
.host-header.open  { border-bottom-color: var(--border); }
.host-ip   { font-family: var(--mono); font-size: 14px; font-weight: 600; }
.host-name { color: var(--muted); font-size: 12px; margin-left: 4px; }
.host-os   { font-size: 11px; color: var(--muted); margin-left: auto; }
.host-badge { margin-left: 8px; }
.chevron { margin-left: auto; color: var(--muted); font-size: 12px; transition: transform .2s; }
.chevron.open { transform: rotate(180deg); }

.host-body { display: none; padding: 1.25rem; }
.host-body.open { display: block; }

/* ── Port table ─────────────────────────────── */
.port-table { width: 100%; border-collapse: collapse; font-size: 13px; }
.port-table th {
  text-align: left; padding: 6px 10px;
  font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .05em;
  color: var(--muted); border-bottom: 1px solid var(--border);
}
.port-table td { padding: 7px 10px; border-bottom: 1px solid var(--border); vertical-align: top; }
.port-table tr:last-child td { border-bottom: none; }
.port-table tr:hover td { background: var(--bg); }
.port-num { font-family: var(--mono); font-size: 12px; }
.svc-product { font-weight: 500; }
.svc-version { color: var(--muted); font-size: 11px; margin-top: 2px; }

/* ── Vuln pills ─────────────────────────────── */
.vuln-list { display: flex; flex-wrap: wrap; gap: 5px; margin-top: 4px; }
.vuln-pill {
  display: inline-flex; align-items: center; gap: 5px;
  font-size: 11px; font-family: var(--mono);
  padding: 2px 8px; border-radius: 99px;
  border: 1px solid;
}
.vuln-pill .score { font-weight: 700; }
.exploit-badge {
  font-size: 9px; font-family: var(--sans);
  text-transform: uppercase; letter-spacing: .05em;
  background: #dc2626; color: #fff;
  padding: 0px 5px; border-radius: 99px;
}

/* severity colour variants */
.sev-critical { background: var(--bg-critical); color: var(--c-critical); border-color: var(--bd-critical); }
.sev-high     { background: var(--bg-high);     color: var(--c-high);     border-color: var(--bd-high);     }
.sev-medium   { background: var(--bg-medium);   color: var(--c-medium);   border-color: var(--bd-medium);   }
.sev-low      { background: var(--bg-low);      color: var(--c-low);      border-color: var(--bd-low);      }
.sev-info     { background: var(--bg-info);     color: var(--c-info);     border-color: var(--bd-info);     }

/* ── Severity badge (host row) ──────────────── */
.sev-badge {
  font-size: 10px; font-weight: 700;
  text-transform: uppercase; letter-spacing: .05em;
  padding: 2px 8px; border-radius: 99px; border: 1px solid;
}

/* ── Vuln detail table ──────────────────────── */
.vuln-table { width: 100%; border-collapse: collapse; font-size: 12px; margin-top: .5rem; }
.vuln-table th {
  text-align: left; padding: 5px 8px;
  font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .05em;
  color: var(--muted); border-bottom: 1px solid var(--border);
}
.vuln-table td { padding: 5px 8px; border-bottom: 1px solid var(--border); }
.vuln-table tr:last-child td { border-bottom: none; }
.cve-link { font-family: var(--mono); font-size: 11px; }

/* ── Args block ─────────────────────────────── */
.args-block {
  font-family: var(--mono); font-size: 11px;
  background: #1e2330; color: #a8b4c8;
  padding: .85rem 1.25rem; border-radius: 8px;
  margin-bottom: 1.5rem;
  word-break: break-all;
}

/* ── Footer ─────────────────────────────────── */
.report-footer {
  text-align: center; color: var(--muted); font-size: 11px; margin-top: 3rem;
}

/* ── No vulns msg ───────────────────────────── */
.no-vulns { color: var(--muted); font-size: 12px; font-style: italic; }

/* ── Filter bar ─────────────────────────────── */
.filter-bar {
  display: flex; gap: 8px; flex-wrap: wrap; margin-bottom: 1rem;
}
.filter-btn {
  font-size: 11px; font-weight: 600; text-transform: uppercase; letter-spacing: .05em;
  padding: 4px 14px; border-radius: 99px; border: 1px solid var(--border);
  background: var(--surface); color: var(--muted); cursor: pointer;
  transition: all .15s;
}
.filter-btn:hover, .filter-btn.active {
  background: var(--text); color: #fff; border-color: var(--text);
}
"""

JS = """
document.querySelectorAll('.host-header').forEach(function(hdr) {
  hdr.addEventListener('click', function() {
    var body = hdr.nextElementSibling;
    var chev = hdr.querySelector('.chevron');
    var open = body.classList.toggle('open');
    hdr.classList.toggle('open', open);
    chev.classList.toggle('open', open);
  });
});

// filter buttons
document.querySelectorAll('.filter-btn').forEach(function(btn) {
  btn.addEventListener('click', function() {
    var sev = btn.dataset.sev;
    document.querySelectorAll('.filter-btn').forEach(function(b) { b.classList.remove('active'); });
    btn.classList.add('active');
    document.querySelectorAll('.host-card').forEach(function(card) {
      if (sev === 'all') {
        card.style.display = '';
      } else {
        card.style.display = (card.dataset.maxsev === sev) ? '' : 'none';
      }
    });
  });
});
"""


def _pill(v: Vuln) -> str:
    cls = severity_class(v.cvss)
    exploit = '<span class="exploit-badge">exploit</span>' if v.is_exploit else ""
    cve_url = f"https://vulners.com/{v.type.lower()}/{v.cve_id}"
    return (
        f'<a class="vuln-pill {cls}" href="{html.escape(cve_url)}" target="_blank" rel="noopener">'
        f'<span class="score">{v.cvss:.1f}</span>'
        f'<span class="id">{html.escape(v.cve_id)}</span>'
        f'{exploit}'
        f'</a>'
    )


def _port_row(port: Port) -> str:
    svc = html.escape(f"{port.product} {port.version} {port.extra}".strip())
    svc_name = html.escape(port.service)
    ver_parts = []
    if port.product: ver_parts.append(port.product)
    if port.version: ver_parts.append(port.version)
    if port.extra:   ver_parts.append(f"({port.extra})")

    pills = ""
    if port.vulns:
        sorted_vulns = sorted(port.vulns, key=lambda v: v.cvss, reverse=True)
        pills = '<div class="vuln-list">' + "".join(_pill(v) for v in sorted_vulns) + "</div>"
    else:
        pills = '<span class="no-vulns">no CVEs reported</span>'

    max_cvss = port_max_cvss(port)
    row_cls = f'class="{severity_class(max_cvss)}"' if max_cvss >= CVSS_LOW else ""

    return f"""
    <tr {row_cls}>
      <td class="port-num">{port.number}/{port.protocol}</td>
      <td><span class="svc-product">{svc_name}</span></td>
      <td>
        <div class="svc-product">{html.escape(" ".join(ver_parts))}</div>
        <div class="svc-version">{" ".join(html.escape(c) for c in port.cpe)}</div>
      </td>
      <td>{pills}</td>
    </tr>"""


def _host_block(host: Host, idx: int) -> str:
    max_cvss = host_max_cvss(host)
    sev = severity_label(max_cvss)
    sev_cls = severity_class(max_cvss)

    open_ports = [p for p in host.ports if p.state == "open"]
    total_vulns = sum(len(p.vulns) for p in open_ports)
    exploitable = sum(1 for p in open_ports for v in p.vulns if v.is_exploit)

    badge = f'<span class="sev-badge {sev_cls}">{sev}</span>' if max_cvss >= CVSS_LOW else ""

    hostname_span = f'<span class="host-name">({html.escape(host.hostname)})</span>' if host.hostname else ""
    os_span = f'<span class="host-os">{html.escape(host.os_hint)}</span>' if host.os_hint else ""

    rows = "".join(_port_row(p) for p in open_ports) if open_ports else \
           "<tr><td colspan='4' class='no-vulns' style='padding:.75rem 10px'>No open ports detected.</td></tr>"

    vuln_count_txt = f"{total_vulns} CVE{'s' if total_vulns != 1 else ''}"
    if exploitable:
        vuln_count_txt += f" &bull; {exploitable} exploit{'s' if exploitable != 1 else ''}"

    return f"""
  <div class="host-card" data-maxsev="{sev}">
    <div class="host-header">
      <span class="host-ip">{html.escape(host.address)}</span>
      {hostname_span}
      {badge}
      <span class="host-badge" style="font-size:11px;color:var(--muted)">{vuln_count_txt}</span>
      {os_span}
      <span class="chevron">&#x25BC;</span>
    </div>
    <div class="host-body">
      <table class="port-table">
        <thead>
          <tr>
            <th>Port</th>
            <th>Service</th>
            <th>Version / CPE</th>
            <th>Vulnerabilities</th>
          </tr>
        </thead>
        <tbody>
          {rows}
        </tbody>
      </table>
    </div>
  </div>"""


def generate_html(meta: ScanMeta, hosts: list[Host]) -> str:
    all_vulns = [v for h in hosts for p in h.ports for v in p.vulns]
    n_critical = sum(1 for v in all_vulns if v.cvss >= CVSS_CRITICAL)
    n_high     = sum(1 for v in all_vulns if CVSS_HIGH <= v.cvss < CVSS_CRITICAL)
    n_medium   = sum(1 for v in all_vulns if CVSS_MEDIUM <= v.cvss < CVSS_HIGH)
    n_low      = sum(1 for v in all_vulns if CVSS_LOW <= v.cvss < CVSS_MEDIUM)
    n_exploits = sum(1 for v in all_vulns if v.is_exploit)

    sorted_hosts = sorted(hosts, key=lambda h: host_max_cvss(h), reverse=True)

    stat_cards = f"""
  <div class="summary-row">
    <div class="stat-card critical"><div class="num">{n_critical}</div><div class="lbl">Critical</div></div>
    <div class="stat-card high">   <div class="num">{n_high}</div>    <div class="lbl">High</div></div>
    <div class="stat-card medium"> <div class="num">{n_medium}</div>  <div class="lbl">Medium</div></div>
    <div class="stat-card low">    <div class="num">{n_low}</div>     <div class="lbl">Low</div></div>
    <div class="stat-card">        <div class="num">{n_exploits}</div><div class="lbl">Exploits</div></div>
    <div class="stat-card">        <div class="num">{meta.hosts_up}</div><div class="lbl">Hosts up</div></div>
    <div class="stat-card">        <div class="num">{len(all_vulns)}</div><div class="lbl">Total CVEs</div></div>
  </div>"""

    host_blocks = "\n".join(_host_block(h, i) for i, h in enumerate(sorted_hosts))

    filter_bar = """
  <div class="filter-bar">
    <button class="filter-btn active" data-sev="all">All</button>
    <button class="filter-btn" data-sev="CRITICAL">Critical</button>
    <button class="filter-btn" data-sev="HIGH">High</button>
    <button class="filter-btn" data-sev="MEDIUM">Medium</button>
    <button class="filter-btn" data-sev="LOW">Low</button>
    <button class="filter-btn" data-sev="INFO">Info / clean</button>
  </div>"""

    generated = datetime.now(tz=timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1.0" />
  <title>Nmap Vulnerability Report</title>
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link href="https://fonts.googleapis.com/css2?family=Inter:wght@400;500;600;700&family=JetBrains+Mono:wght@400;600&display=swap" rel="stylesheet" />
  <style>{CSS}</style>
</head>
<body>
<div class="page">

  <div class="report-header">
    <div>
      <div class="report-title">Vulnerability Report</div>
      <div class="report-subtitle">Nmap &middot; vulners NSE script &middot; Generated {generated}</div>
    </div>
    <div class="report-meta-grid">
      <span class="label">Scan start</span><span class="value">{meta.start_ts}</span>
      <span class="label">Scan end</span>  <span class="value">{meta.end_ts}</span>
      <span class="label">Duration</span>  <span class="value">{meta.elapsed}</span>
    </div>
  </div>

  <div class="args-block">$ {html.escape(meta.args)}</div>

  {stat_cards}

  <div class="section-title">Hosts &mdash; sorted by severity</div>
  {filter_bar}
  {host_blocks}

  <div class="report-footer">
    Nmap &bull; vulners NSE &bull; Report generated {generated}
  </div>

</div>
<script>{JS}</script>
</body>
</html>"""


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

def main() -> None:
    ap = argparse.ArgumentParser(
        description="Parse Nmap XML (vulners) → HTML report"
    )
    ap.add_argument("xml", type=Path, help="Nmap XML output file (-oX)")
    ap.add_argument("-o", "--output", type=Path, default=None,
                    help="Output HTML file (default: <xml>.html)")
    args = ap.parse_args()

    if not args.xml.exists():
        print(f"[!] File not found: {args.xml}", file=sys.stderr)
        sys.exit(1)

    out_path: Path = args.output or args.xml.with_suffix(".html")

    print(f"[*] Parsing {args.xml} …")
    meta, hosts = parse_xml(args.xml)

    all_vulns = [v for h in hosts for p in h.ports for v in p.vulns]
    print(f"[+] Hosts: {len(hosts)}  Open-port records parsed")
    print(f"[+] CVEs found: {len(all_vulns)}")

    html_out = generate_html(meta, hosts)
    out_path.write_text(html_out, encoding="utf-8")
    print(f"[+] Report saved → {out_path}")


if __name__ == "__main__":
    main()
