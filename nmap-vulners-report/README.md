# nmap-vulners-report

A zero-dependency Python script that parses Nmap XML output produced with the **vulners** NSE script and generates a professional, self-contained HTML report.

---

## Features

- Parses standard Nmap `-oX` (XML) output enriched by the `vulners` NSE plugin
- Produces a **single, self-contained HTML file**: no server, no framework, no extra dependencies
- Hosts sorted by highest CVSS score, each collapsible for a clean overview
- Per-port **CVE pills** colour-coded by severity (Critical / High / Medium / Low)
- Red **exploit** badge on CVEs that have a known public exploit
- Each pill links directly to the corresponding Vulners entry
- Scan-level **summary cards**: Critical, High, Medium, Low, total CVEs, exploitable findings, hosts up
- **Filter bar** to narrow the host list by severity level at a glance
- Scan command rendered in a terminal-style block for full reproducibility
- Gracefully handles hosts with no open ports or no CVEs reported

---

## Requirements

- Python **3.10** or later
- Standard library only - no `pip install` needed
- Nmap with the [`vulners`](https://github.com/vulnersCom/nmap-vulners) NSE script installed

---

## Installation

```bash
git clone https://github.com/yourname/nmap-vulners-report.git
cd nmap-vulners-report
# No install step needed - run directly
```

---

## Usage

### 1 - Run Nmap with vulners and XML output

```bash
nmap -sV --script vulners -oX scan.xml 192.168.1.0/24
```

> **Tip:** Add `-p-` to scan all ports, or `-T4` to speed things up on a trusted network.  
> The `vulners` script requires `-sV` (service/version detection) to work.

### 2 - Generate the HTML report

```bash
# Output written alongside the XML (scan.html)
python3 nmap_vulners_report.py scan.xml

# Explicit output path
python3 nmap_vulners_report.py scan.xml -o /tmp/report.html
```

Open the resulting `.html` file in any browser. No internet connection required to view it (Google Fonts are loaded from a CDN for aesthetics but the report degrades gracefully without them).

---

## CLI reference

```
usage: nmap_vulners_report.py [-h] [-o OUTPUT] xml

positional arguments:
  xml                   Nmap XML output file (-oX)

options:
  -h, --help            show this help message and exit
  -o, --output OUTPUT   Output HTML file (default: <xml>.html)
```

---

## CVSS severity thresholds

| Severity | CVSS range |
|----------|-----------|
| Critical | 9.0 – 10.0 |
| High     | 7.0 – 8.9  |
| Medium   | 4.0 – 6.9  |
| Low      | 0.1 – 3.9  |
| Info     | 0.0 (no CVEs) |

These map directly to the colour scheme used in the report pills and host badges.

---

## Report structure

```
┌─ Header ─────────────────────────────────────────┐
│  Title · generation timestamp · scan start/end   │
├─ Scan command ────────────────────────────────────┤
│  $ nmap -sV --script vulners ...                  │
├─ Summary cards ───────────────────────────────────┤
│  Critical  High  Medium  Low  Exploits  Hosts  CVEs│
├─ Filter bar ──────────────────────────────────────┤
│  [ All ] [ Critical ] [ High ] [ Medium ] [ Low ] │
├─ Host list (sorted by max CVSS, collapsible) ─────┤
│  ▼ 192.168.1.10  (web01.corp.local)  CRITICAL     │
│     Port   Service   Version / CPE   CVEs          │
│     80/tcp http      Apache 2.4.29   ●9.8 ●9.8 …  │
│  ▶ 192.168.1.20  (db01.corp.local)   MEDIUM        │
│  ▶ 192.168.1.50  (ws-dev01)          INFO          │
└───────────────────────────────────────────────────┘
```

---

## Tested with

| Nmap version | vulners script | OS |
|---|---|---|
| 7.94 | 2.1.1 | Ubuntu 22.04, macOS 14 |
| 7.80 | 2.0.0 | Kali Linux 2024.1 |

---

## Limitations

- Only parses output from the `vulners` NSE script. Other vuln scripts (e.g. `vulscan`) produce different XML structures and are not currently supported.
- OS detection data (`-O`) is parsed opportunistically from the first `osmatch` element; it requires a separate `-O` flag in your Nmap command.
- The script reads the XML in a single pass and holds the full model in memory; fine for typical pentest scopes, but very large scans (10 000+ hosts) may be slow.

---

## License

MIT
