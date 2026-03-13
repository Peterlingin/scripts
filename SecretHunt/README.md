# 🕵️ SecretHunt

A fast, zero-dependency Bash script that hunts for leaked secrets and credentials hiding in your shell history files. No setup, no installation. Just run it and find out what your terminal has been keeping from you.

---

## Table of Contents

- [Why It Exists](#why-it-exists)
- [Requirements](#requirements)
- [Usage](#usage)
- [Options](#options)
- [What It Detects](#what-it-detects)
- [Output](#output)
  - [Terminal Output](#terminal-output)
  - [CSV Report](#csv-report)
  - [Exit Codes](#exit-codes)
- [Testing with inject_test_secrets.sh](#testing-with-inject_test_secretssh)
- [How It Works](#how-it-works)
- [Limitations](#limitations)
- [CI/CD Integration](#cicd-integration)

---

## Why It Exists

Most developers have typed a password, API key, or token directly into the terminal at least once. Maybe it was a quick `curl` with credentials, an `export SECRET_KEY=...` before running a script, or a database connection string pasted in a hurry. Those commands never disappear. They sit quietly in your shell history.

SecretHunt finds them before someone else does.

---

## Requirements

| Dependency | Notes |
|------------|-------|
| `bash` ≥ 4.0 | Pre-installed on most Linux/macOS systems |
| `awk` | Used only for entropy calculation on matches |

No other dependencies. No Python, no Node, no package manager.

---

## Usage

```
./secrethunt.sh [OPTIONS]
```

By default, SecretHunt automatically scans all history files it can find for the current user.

---

## Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `-f` | `FILE` | *(auto)* | Scan a specific history file instead of the defaults |
| `-s` | `SEVERITY` | `low` | Minimum severity to report: `low`, `medium`, or `high` |
| `-o` | `FILE` | *(none)* | Save a CSV report to `FILE` |
| `-q` | — | `false` | Quiet mode: suppress banner and summary, show findings only |
| `-h` | — | — | Print help and exit |

---

## What It Detects

SecretHunt uses **30 regex patterns** grouped into three severity levels, combined with **Shannon entropy scoring** on every match to help distinguish real secrets from placeholder values.

### 🔴 High — Known secret formats

Patterns that match the exact structure of real credentials issued by specific platforms:

- AWS Access Key IDs and Secret Access Keys
- GitHub personal access tokens (classic and fine-grained)
- Stripe secret and publishable keys
- Twilio Account SIDs and Auth Tokens
- SendGrid API keys
- Slack bot and app tokens, incoming webhooks
- Google API keys and OAuth tokens
- Heroku API keys
- npm auth tokens
- Private key file headers (RSA, EC, OPENSSH, DSA)
- JSON Web Tokens (JWT)
- Database connection strings with embedded credentials (MySQL, PostgreSQL, MongoDB, Redis)
- Bearer tokens in Authorization headers
- Basic auth credentials embedded in URLs

### 🟠 Medium — Generic credential assignments

Patterns that match common variable naming conventions paired with non-trivial values:

- `api_key=`, `apikey=`, `api-key=` assignments with values of 16+ characters
- `client_secret=`, `app_secret=`, `secret_key=` assignments
- `auth_token=`, `access_token=` assignments
- `password=`, `passwd=`, `pwd=` assignments with values of 6+ characters
- SSH identity file flags (`-i file.pem`)
- `curl` commands with `-u` or `--user` credentials

### 🟡 Low — Suspicious environment variable usage

Patterns that indicate credentials may have been passed via environment variables or shell exports:

- `export API_KEY=`, `export SECRET=`, `export TOKEN=`, `export PASSWORD=` and similar
- Direct env var assignments like `DB_PASSWORD=... command`
- `scp` and `rsync` commands with key file arguments
- `sshpass -p` commands with inline passwords

---

## Output

### Terminal Output

Each finding is printed as a colour-coded block with the severity level, line number, detection type, the matched value, and its entropy score:

```
────────────────────────────────────────────────────────────
Scanning: /home/user/.zsh_history

  HIGH   Line 142 — AWS Access Key ID
         aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE
         Entropy: 4.31 bits  |  Match: AKIAIOSFODNN7EXAMPLE

  MEDIUM Line 891 — Generic Password
         mysqldump -u root --password=Tr0ub4dor mydb > backup.sql
         Entropy: 3.76 bits  |  Match: password=Tr0ub4dor

────────────────────────────────────────────────────────────
Summary
  Lines scanned : 3241
  Total findings: 7
  High: 3  |  Medium: 2  |  Low: 2
```

**Entropy** is reported in bits using the Shannon entropy formula. Higher values indicate more randomness — a real API key typically scores above 3.5 bits, while a placeholder like `password=test` scores much lower.

### CSV Report

When `-o FILE` is specified, a CSV file is written with the following columns:

| Column | Description |
|--------|-------------|
| `File` | Path to the history file where the finding was detected |
| `Line` | Line number within that file |
| `Severity` | `high`, `medium`, or `low` |
| `Type` | Human-readable label for the pattern that matched |
| `Match` | The matched string (truncated to 100 characters) |
| `Entropy` | Shannon entropy of the matched value in bits |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | No findings detected |
| `1` | One or more findings detected |

---

## Testing with inject_test_secrets.sh

A companion script `inject_test_secrets.sh` is provided to populate your history file with **23 fake but structurally realistic credentials** across all three severity levels, so you can verify that SecretHunt is working correctly without needing real secrets. All injected values are either taken from official documentation examples (such as Amazon's own example AWS keys) or are completely fictional strings that follow the correct format but don't correspond to any real account. Run it before testing SecretHunt, then clean up your history afterwards.

---

## How It Works

1. **Discover history files** — scans `~/.bash_history`, `~/.zsh_history`, and `~/.local/share/fish/fish_history` by default, or a custom file via `-f`.
2. **Strip shell metadata** — fish history entries include timestamps in the format `: 1699999999:0;command` which are stripped before matching.
3. **Match patterns** — each line is tested against all 30 patterns using bash's built-in `[[ =~ ]]` regex operator. No external processes are spawned per line.
4. **Score entropy** — when a match is found, the matched string's Shannon entropy is calculated via `awk` to help assess whether the value looks like a real secret.
5. **Report** — findings are printed to the terminal with colour-coded severity and optionally written to a CSV file.
6. **Exit** — exits with code `0` if clean, `1` if any findings were detected.

### Performance design

SecretHunt is designed to avoid the most common performance pitfalls in bash scripting:

- All pattern matching uses bash's built-in `[[ =~ ]]` — no `grep` subshell per line
- Severity filtering uses integer arithmetic — no subshells
- String truncation uses bash parameter expansion (`${var:0:N}`) — no `cut` subshells
- Entropy is computed only when a match is found, not on every line
- Fish timestamp stripping uses parameter expansion — no `sed` per line

On a modern machine, a 10,000-line history file scans in well under a second.

---

## Limitations

- **Regex-based detection** will produce false positives (innocent strings that look like secrets) and false negatives (real secrets that don't match any pattern). Entropy scoring helps reduce false positives but does not eliminate them.
- **Obfuscated or encoded secrets** — base64-encoded credentials or secrets split across multiple commands will not be detected.
- **In-memory secrets** — secrets that were set and used entirely within a single session without being written to history are not visible to this tool.
- **Not a replacement** for dedicated secret scanning tools like `truffleHog` or `gitleaks` when scanning codebases or git history.

---

## CI/CD Integration

SecretHunt's exit code makes it usable as a lightweight pre-commit or pipeline gate.

### Pre-commit hook

```bash
# .git/hooks/pre-commit
./secrethunt.sh -s high -q
if [[ $? -ne 0 ]]; then
  echo "SecretHunt: high-severity secrets found in shell history. Review before committing."
  exit 1
fi
```

### GitHub Actions

```yaml
- name: Scan shell history for secrets
  run: |
    chmod +x secrethunt.sh
    ./secrethunt.sh -s medium -o secrethunt_report.csv

- name: Upload findings
  if: always()
  uses: actions/upload-artifact@v3
  with:
    name: secrethunt-report
    path: secrethunt_report.csv
```

---

> **Tip:** Run with `-s high -q` for a fast, noise-free check that only surfaces the most critical findings. Pipe the output to a file for a clean audit trail: `./secrethunt.sh -s high -q -o report.csv`

