# tracker_analyzer

A local, scriptable, privacy-preserving website tracker scanner. Loads pages with a real headless browser, simulates user interaction, and produces terminal, JSON, CSV, and HTML reports identifying every tracker, cookie, and iframe it finds.

Built with Claude (Anthropic).

---

## Why this exists

Most tracker scanning tools are web services: you paste a URL, their server fetches it, and you get a report. That works fine for public pages. It does not work for staging environments, intranet tools, pages behind authentication, or anything you would rather not send to a third party.

This script runs entirely on your machine. It is also automatable, which means you can drop it into a CI pipeline, run it on a schedule, and diff results across time to catch new trackers the moment they appear.

---

## What it detects

The scanner uses three detection layers in combination:

**Network requests** match outgoing URLs against two sources: a hand-curated database of ~90 named tools (Google Analytics, Meta Pixel, Hotjar, OneTrust, and so on) and the EasyPrivacy + disconnect.me blocklists, which together cover 50,000+ rules. Anything matched by the blocklist but not by a named signature is flagged with its hostname, so nothing slips through unnamed.

**JavaScript globals** inspect `window.*` keys and inline `<script>` blocks for known tracker fingerprints after the page has fully executed.

**Cookies** are matched against 24 known tracking cookie patterns, with security flags (HttpOnly, Secure, SameSite, expiry) reported for every cookie captured.

**Iframes and embeds** are scanned recursively across all frames, including nested cross-origin frames, against 20 known embed signatures. Noscript fallback pixels are included.

Categories covered: Analytics, Tag Manager, Advertising, Heatmap/Session Recording, A/B Testing, Customer Engagement / CRM, Consent Management Platforms, Performance Monitoring, Social/Media Embeds, Security widgets.

---

## How it works

1. Chromium launches headlessly via Playwright with a realistic user-agent string
2. The page loads and reaches network idle
3. If a consent banner is detected, it is automatically dismissed (supports OneTrust, Cookiebot, Iubenda, Didomi, Usercentrics, and generic "Accept all" patterns in English, Italian, French, and German)
4. After consent, the browser scrolls the page in four steps and moves the mouse to trigger lazy-loaded and deferred trackers
5. All frames are recursively scanned for scripts, globals, and iframes
6. Cookies are captured from the browser context
7. Every network request, cookie, and iframe is matched against all detection layers
8. Results are merged, deduplicated, and written to terminal + JSON + CSV + HTML

The EasyPrivacy and disconnect.me blocklists are cached locally for 24 hours at `~/.cache/tracker_analyzer/` to avoid hammering public servers on every run. The cache refreshes automatically when stale.

---

## Installation

Python 3.10 or later is required.

Install dependencies:

```bash
pip install playwright rich
```

Install the Chromium browser binary:

```bash
playwright install chromium
```

That is everything. No database, no server, no API key.

---

## Usage

Basic scan:

```bash
python tracker_analyzer.py https://example.com
```

Custom output directory:

```bash
python tracker_analyzer.py https://example.com --output-dir ./reports
```

Diff against a previous scan:

```bash
python tracker_analyzer.py https://example.com --diff ./reports/trackers_example_com_20260401_120000.json
```

Skip consent banner bypass:

```bash
python tracker_analyzer.py https://example.com --no-accept
```

Skip scroll/interaction simulation (faster, less thorough):

```bash
python tracker_analyzer.py https://example.com --no-interact
```

Skip blocklist download (use built-in signatures only):

```bash
python tracker_analyzer.py https://example.com --no-blocklist
```

Custom page load timeout (default is 30 seconds):

```bash
python tracker_analyzer.py https://example.com --timeout 60
```

All options combined:

```bash
python tracker_analyzer.py https://example.com \
  --output-dir ./reports \
  --diff ./reports/trackers_example_com_yesterday.json \
  --timeout 45
```

---

## Output

Each scan produces three files, named `trackers_<domain>_<timestamp>.*`:

**Terminal** prints a formatted table with Rich, showing each tracker, its category, detection source (built-in signature or blocklist), detection method, and evidence. A category breakdown and diff summary follow.

**JSON** contains the full report: all trackers with metadata, every raw cookie, every iframe source, blocklist provenance, and diff results if requested. This is the machine-readable format intended for pipelines.

**CSV** contains the tracker table only, suitable for spreadsheet analysis or importing into other tools.

**HTML** is a self-contained single-file report with no external dependencies. It opens directly in any browser. It includes the tracker count with a category breakdown bar chart, a filterable tracker table, a full cookie table with security flag indicators, an iframe/embed table, and a diff section when a previous scan is provided.

---

## Run diffing

Pass any previous JSON report with `--diff` and the scanner will compare the two runs, highlighting trackers that appeared or disappeared between scans. New trackers are marked in the terminal output and the HTML report.

This is particularly useful for monitoring: run the scanner weekly, always diffing against the previous report, and you will know the moment a new tracking pixel is added to a site.

```bash
# Week 1
python tracker_analyzer.py https://example.com -o ./reports

# Week 2
python tracker_analyzer.py https://example.com -o ./reports \
  --diff ./reports/trackers_example_com_20260403_090000.json
```

---

## CI / automation

Because the script is a standard Python process that exits with code 1 on failure, it fits naturally into any pipeline. A minimal GitHub Actions example:

```yaml
- name: Scan for trackers
  run: |
    pip install playwright rich
    playwright install chromium
    python tracker_analyzer.py https://staging.example.com \
      --output-dir ./tracker-reports \
      --no-accept \
      --no-interact

- name: Upload report
  uses: actions/upload-artifact@v4
  with:
    name: tracker-report
    path: ./tracker-reports/
```

Remove `--no-accept` and `--no-interact` if you want the full scan including consent bypass and interaction simulation. Expect scans to take 20 to 60 seconds depending on the target site.

---

## Updating Playwright

Playwright itself:

```bash
pip install --upgrade playwright
```

Chromium binaries (always run this after upgrading Playwright):

```bash
playwright install chromium
```

The blocklists update automatically on first use after 24 hours. To force an immediate refresh, delete the cache:

```bash
rm -rf ~/.cache/tracker_analyzer/
```

---

## Comparison with similar tools

| | tracker_analyzer | BlackLight (The Markup) | Cookiebot Scanner | Browser extensions (uBlock, Privacy Badger) |
|---|---|---|---|---|
| Runs locally | Yes | No | No | Yes |
| No URL sent to third party | Yes | No | No | Yes |
| Scans staging / authenticated pages | Yes | No | No | Yes |
| Scriptable / CI integration | Yes | No | No | No |
| Run diffing across time | Yes | No | No | No |
| Consent banner bypass | Yes | Yes | Partial | No |
| Interaction simulation | Yes | Yes | No | No |
| Blocklist size | 50,000+ rules | Very large | Medium | Very large |
| Named tool identification | Yes (~90 tools) | Yes | Yes | Partial |
| Cookie security flag report | Yes | No | Yes | No |
| Nested iframe scanning | Yes | Partial | No | No |
| HTML report | Yes | Web UI only | Web UI only | No |
| JSON / CSV export | Yes | No | Paid only | No |
| Free | Yes | Yes | Freemium | Yes |

**BlackLight** by The Markup is the gold standard for one-off manual audits and research. Its detection is more comprehensive than this script for public pages. It is not automatable and does not run locally, which are the two main reasons this script exists.

**Cookiebot Scanner** focuses specifically on cookie compliance and produces reports suitable for GDPR documentation. It is a web service, exports are behind a paywall, and it cannot scan non-public pages.

**Browser extensions** like uBlock Origin and Privacy Badger run locally and use large blocklists, but they are interactive tools, not scanners. They block trackers rather than report on them, produce no structured output, and cannot be run headlessly.

This script is not trying to replace any of them. It targets a specific gap: automated, private, diff-aware scanning with structured output, on pages that cannot or should not be sent to a third-party service.

---

## Limitations

Being transparent about what this tool does not do well is important.

**Trackers that fire only on specific interactions** (form submissions, purchases, video plays) will be missed. The interaction simulation covers scroll and mouse movement, but not arbitrary user flows.

**Sophisticated headless detection** can cause some sites to serve a different page to Playwright than to a real browser. The script uses a realistic user-agent string but does not apply stealth patches.

**Blocklist false positives** are possible. A URL matched by a blocklist rule is flagged as Advertising by default, which may not be accurate for every match.

**Single page only.** The script scans one URL per run. Multi-page crawling is out of scope.

**Not a compliance tool.** The output is useful evidence for privacy audits, but it is not a legal GDPR/CCPA compliance report and should not be treated as one.

---

## Authorship

Designed and built with [Claude](https://claude.ai) (Anthropic). The tool's scope, feature set, detection approach, report design, and iteration decisions were made collaboratively. The code was generated by Claude.

---

## License

MIT

