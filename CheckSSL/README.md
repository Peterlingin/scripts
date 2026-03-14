# SSL Certificate Checker

A Bash script that validates SSL/TLS certificates for a list of domains read from a plain-text file, or interactively for a single domain passed directly on the command line. It reports expiry status with colour-coded output, supports per-domain custom ports, optional CSV export, and integrates cleanly into CI/CD pipelines.

---

## Table of Contents

- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
- [Domain File Format](#domain-file-format)
- [Examples](#examples)
- [Output](#output)
  - [Terminal Output](#terminal-output)
  - [CSV Report](#csv-report)
  - [Exit Codes](#exit-codes)
- [How It Works](#how-it-works)
- [CI/CD Integration](#cicd-integration)
- [Troubleshooting](#troubleshooting)

---

## Requirements

| Dependency | Notes |
|------------|-------|
| `bash` ≥ 4.0 | Pre-installed on most Linux/macOS systems |
| `openssl` | Used to fetch and parse certificates |
| `date` | GNU `date` (Linux) or BSD `date` (macOS) — both supported |
| `timeout` | Part of GNU coreutils (Linux); on macOS install via `brew install coreutils` |

---

## Usage

The script supports two modes:

**File mode** — reads domains from a text file:
```
./check_ssl.sh <domains.txt> [OPTIONS]
```

**Interactive mode** — checks a single domain passed on the command line, then prompts for more:
```
./check_ssl.sh -d DOMAIN [OPTIONS]
```

---

## Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `-d` | `DOMAIN` | *(none)* | Check a single domain directly; ignores the domain file and enters interactive mode |
| `-p` | `PORT` | `443` | Default port used for all domains that don't specify their own |
| `-w` | `DAYS` | `30` | Emit a warning if a certificate expires within this many days |
| `-t` | `SECONDS` | `10` | Connection timeout per domain |
| `-o` | `FILE` | *(none)* | Save a CSV report to `FILE` |
| `-q` | — | `false` | Quiet mode: suppress informational output, show only warnings and errors |
| `-h` | — | — | Print help and exit |

---

## Domain File Format

Create a plain-text file with one domain per line.

```
# SSL Certificate Check — Domain List
# Lines starting with # are comments and are ignored.
# Blank lines are also ignored.

example.com
google.com
github.com

# Append a custom port with a colon (overrides the -p default)
internal.mycompany.com:8443
staging.myapp.io:4443
```

**Rules:**

- One domain per line.
- Lines beginning with `#` are treated as comments.
- Blank lines are skipped.
- Append `:<port>` to override the default port for a specific domain (e.g. `myservice.com:8443`).

---

## Examples

**Basic check against a domain file:**
```bash
./check_ssl.sh domains.txt
```

**Interactive single-domain check:**
```bash
./check_ssl.sh -d github.com
```

**Interactive check on a non-standard port:**
```bash
./check_ssl.sh -d internal.mycompany.com:8443
```

**Warn if a certificate expires within 60 days:**
```bash
./check_ssl.sh domains.txt -w 60
./check_ssl.sh -d github.com -w 60
```

**Check all file domains on port 8443:**
```bash
./check_ssl.sh domains.txt -p 8443
```

**Save results to a CSV file:**
```bash
./check_ssl.sh domains.txt -o report.csv
./check_ssl.sh -d github.com -o report.csv
```

**Quiet mode with a CSV report (ideal for cron jobs):**
```bash
./check_ssl.sh domains.txt -q -o /var/log/ssl_report.csv
```

**Combine multiple options:**
```bash
./check_ssl.sh domains.txt -w 60 -t 5 -o report.csv -q
```

---

## Output

### Terminal Output

Each domain produces a colour-coded block:

```
────────────────────────────────────────────────────────────
github.com:443
  Status  : ✅ VALID (87 days left — Mar 26 00:00:00 2026 GMT)
  Issuer  : C=US, O=DigiCert Inc, CN=DigiCert TLS RSA SHA256 2020 CA1
  Subject : CN=github.com
  Valid from: Dec 19 00:00:00 2024 GMT

expired.badssl.com:443
  Status  : ❌ EXPIRED (1234 days ago — Apr 12 00:00:00 2021 GMT)
  ...
```

| Colour | Meaning |
|--------|---------|
| 🟢 Green | Certificate is valid and not expiring soon |
| 🟡 Yellow | Certificate expires within the warning threshold (`-w`) |
| 🔴 Red | Certificate has already expired or could not be retrieved |

**Summary line** at the end:

```
────────────────────────────────────────────────────────────
Summary  —  Total: 5  ✅ Valid: 3  ⚠️ Expiring: 1  ❌ Failed/Expired: 1
```

### Interactive Mode

When using `-d`, after the initial domain is checked the script enters an interactive loop, prompting for additional domains until you quit:

```
────────────────────────────────────────────────────────────
Enter another domain to check (or 'q' to quit): google.com

google.com:443
  Status  : ✅ VALID (210 days left — ...)
  ...

────────────────────────────────────────────────────────────
Enter another domain to check (or 'q' to quit): internal.mycompany.com:8443

internal.mycompany.com:8443
  Status  : ⚠️ EXPIRING SOON (12 days left — ...)
  ...

────────────────────────────────────────────────────────────
Enter another domain to check (or 'q' to quit): q
```

Type `q`, `quit`, or press Enter on an empty line to exit. The summary is printed once at the end covering all domains checked during the session.

### CSV Report

When `-o FILE` is specified, a CSV file is written with the following columns:

| Column | Description |
|--------|-------------|
| `Domain` | The domain name |
| `Port` | Port checked |
| `Status` | `VALID`, `EXPIRING_SOON`, `EXPIRED`, or `UNREACHABLE` |
| `Expiry Date` | Certificate `notAfter` value |
| `Days Remaining` | Integer days until expiry (negative = already expired) |
| `Issuer` | Certificate issuer distinguished name |
| `Subject` | Certificate subject distinguished name |

Example CSV output:

```csv
Domain,Port,Status,Expiry Date,Days Remaining,Issuer,Subject
github.com,443,VALID,Mar 26 00:00:00 2026 GMT,87,"C=US, O=DigiCert Inc","CN=github.com"
expired.badssl.com,443,EXPIRED,Apr 12 00:00:00 2021 GMT,-1234,"C=US, O=BadSSL","CN=*.badssl.com"
unreachable.example.com,443,UNREACHABLE,,,,
```

The CSV report works in both file mode and interactive mode.

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | All certificates are valid and not expiring soon |
| `1` | One or more certificates are expired, expiring soon, or unreachable |

This makes the script safe to use as a gate in CI/CD pipelines.

---

## How It Works

1. **Determine the mode** — if `-d` is supplied the script runs in interactive mode; otherwise it reads from the domain file.
2. **Read domains** — in file mode, domains are read line by line, skipping comments and blank lines. In interactive mode, the first domain comes from `-d`, then the script prompts for more.
3. **Connect with OpenSSL** — for each domain, `openssl s_client` opens a TLS connection using SNI (`-servername`), then `openssl x509` extracts the certificate metadata.
4. **Parse the expiry date** — the `notAfter` field is converted to a Unix timestamp using either GNU `date` (Linux) or BSD `date` (macOS), and the number of remaining days is calculated.
5. **Evaluate the status** — the remaining days are compared against the warning threshold (`-w`) to determine `VALID`, `EXPIRING_SOON`, `EXPIRED`, or `UNREACHABLE`.
6. **Report results** — colour-coded output is printed to the terminal, and optionally a CSV row is appended to the report file.
7. **Exit** — the script exits with code `0` if everything is healthy, or `1` if any issue was found.

---

## CI/CD Integration

The script's exit code makes it a natural fit for automated pipelines.

### GitHub Actions

```yaml
- name: Check SSL certificates
  run: |
    chmod +x check_ssl.sh
    ./check_ssl.sh domains.txt -w 30 -o ssl_report.csv

- name: Upload SSL report
  if: always()
  uses: actions/upload-artifact@v3
  with:
    name: ssl-report
    path: ssl_report.csv
```

### Cron job (Linux)

```cron
# Run every Monday at 08:00
0 8 * * 1 /opt/scripts/check_ssl.sh /opt/scripts/domains.txt -q -o /var/log/ssl_report.csv
```

### GitLab CI

```yaml
ssl-check:
  stage: verify
  script:
    - chmod +x check_ssl.sh
    - ./check_ssl.sh domains.txt -w 30
  artifacts:
    paths:
      - ssl_report.csv
    when: always
```

---

## Troubleshooting

**`Could not retrieve certificate` for a valid domain**

- The server may be blocking automated connections. Try increasing the timeout: `-t 30`.
- Verify connectivity: `openssl s_client -connect domain.com:443 -servername domain.com`

**`timeout: command not found` on macOS**

- Install GNU coreutils: `brew install coreutils`

**Wrong expiry date on macOS**

- Ensure you are using Bash ≥ 4: `bash --version`
- Install a newer Bash via Homebrew if needed: `brew install bash`

**Self-signed or internal CA certificates**

- `openssl s_client` will still retrieve the certificate even if it cannot verify the chain. Expiry dates will be reported correctly. Verification errors are expected and suppressed.

**Interactive mode doesn't prompt after `-d`**

- Make sure you are running the script in a proper terminal (not piped or redirected), as `read` requires an interactive TTY.

---

> **Tip:** In interactive mode, you can type `domain:port` at the prompt (e.g. `myservice.com:8443`) to override the default port on a per-query basis.
