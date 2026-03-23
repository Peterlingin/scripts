# fim - File Integrity Monitor (FIM)

A lightweight, zero-dependency Bash script that detects unauthorised changes to critical system files by comparing SHA-256 hashes against a trusted baseline. Designed for production Linux systems with PCI DSS Requirement 11.5 compliance in mind, and built to run with no external dependencies beyond standard GNU/Linux tools.

---

## Table of Contents

- [Why It Exists](#why-it-exists)
- [Requirements](#requirements)
- [Installation](#installation)
- [Usage](#usage)
- [Options](#options)
- [Configuration](#configuration)
- [How It Works](#how-it-works)
- [Monitored Paths](#monitored-paths)
- [Excluding Files](#excluding-files)
- [Output](#output)
  - [Terminal Output](#terminal-output)
  - [Audit Log](#audit-log)
  - [Syslog Integration](#syslog-integration)
  - [CSV Report](#csv-report)
  - [Exit Codes](#exit-codes)
- [Tamper Detection](#tamper-detection)
- [File Hardening](#file-hardening)
- [PCI DSS Compliance](#pci-dss-compliance)
- [CI/CD Integration](#cicd-integration)
- [Limitations](#limitations)

---

## Why It Exists

Enterprise FIM solutions like AIDE and Tripwire are powerful but come with a significant operational burden - complex configuration, heavyweight dependencies, and licensing costs that put them out of reach for small teams and startups. Yet PCI DSS Requirement 11.5 applies regardless of company size.

FIM fills that gap: a single self-contained script, deployable in minutes, that covers the core requirement with no package installation, no daemon, and no licence fee. It is not a replacement for enterprise solutions on large or complex infrastructures, but it is a fully legitimate and auditable implementation of the requirement for systems where simplicity and transparency matter.

---

## Requirements

| Dependency | Notes |
|------------|-------|
| `bash` ≥ 4.0 | Pre-installed on all modern Linux distributions |
| `sha256sum` | Part of GNU coreutils - present on all Debian/RHEL-based systems |
| `find` | Part of GNU findutils |
| `stat` | Part of GNU coreutils - cross-platform (Linux and macOS) |
| `awk` | Used for single-pass baseline comparison and entropy calculation |
| `logger` | Part of util-linux - used for syslog integration |
| `chattr` | Part of e2fsprogs - used for append-only audit log protection (Linux only) |
| `mail` | Optional - only required if `--email` is used |

No Python, no Node.js, no package manager. Everything is available on a standard Debian or RHEL installation out of the box.

---

## Installation

```bash
# 1. Copy the script to a permanent location
cp fim.sh /opt/fim/fim.sh

# 2. Make it executable
chmod 700 /opt/fim/fim.sh

# 3. Run the initial baseline scan
# The baseline directory /var/lib/fim is created automatically
sudo /opt/fim/fim.sh --init

# 4. Verify the first check works
sudo /opt/fim/fim.sh --check
```

---

## Usage

```
fim.sh [--init | --check] [OPTIONS]
```

The script operates in two modes. `--init` builds or rebuilds the trusted baseline. `--check` compares the current state of the filesystem against that baseline and reports any differences.

**First run - build the baseline:**
```bash
sudo ./fim.sh --init
```

**Subsequent runs - check integrity:**
```bash
sudo ./fim.sh --check
```

**Check with CSV report:**
```bash
sudo ./fim.sh --check --report /var/log/fim/fim_report_$(date +%Y%m%d).csv
```

**Check with email alert:**
```bash
sudo ./fim.sh --check --email soc@company.com
```

---

## Options

| Flag | Argument | Default | Description |
|------|----------|---------|-------------|
| `--init` | - | - | Create or rebuild the baseline database |
| `--check` | - | - | Compare current state against baseline (default) |
| `--baseline` | `FILE` | `/var/lib/fim/baseline.db` | Use a custom baseline file path |
| `--paths` | `FILE` | *(built-in)* | Load monitored paths from a custom file |
| `--report` | `FILE` | *(none)* | Save findings to a CSV report file |
| `--email` | `ADDRESS` | *(none)* | Send alert email on findings |
| `--exclude` | `GLOB` | *(none)* | Exclude files whose **filename** matches GLOB pattern - matched against filename only, not full path (repeatable) |
| `-q` | - | `false` | Quiet mode - suppress banner and info output |
| `-h` | - | - | Print help and exit |

---

## Configuration

At the top of the script there is a small configuration block intended to be edited once at deployment time:

```bash
# ── Configuration ─────────────────────────────────────────────────────────────
META_OVERRIDE=""   # e.g. "/mnt/fim-evidence/fim_meta.sha256"
```

`META_OVERRIDE` sets the path where `fim_meta.sha256` is stored. By default it sits alongside `baseline.db` in `/var/lib/fim/`. For production systems it is strongly recommended to override this to a separate, more secure location. See the [File Hardening](#file-hardening) section for guidance.

---

## Excluding Files

The `--exclude` option passes a glob pattern to `find` via its `-name` flag. This means it matches against the **filename only**, not the full path.

```bash
# Exclude all .log files anywhere in the monitored paths
sudo ./fim.sh --check --exclude "*.log"

# Exclude editor swap files and Python bytecode
sudo ./fim.sh --check --exclude "*.swp" --exclude "*.pyc"

# Exclude a specific filename everywhere it appears
sudo ./fim.sh --check --exclude "resolv.conf"
```

**Important limitations to understand:**

The pattern is matched against the filename part only. `--exclude "/etc/resolv.conf"` will not work - `find` will never match a full path with the `-name` flag. To exclude a specific file at a specific path (e.g. only `/etc/resolv.conf` but not `/backup/resolv.conf`), the correct approach is to use a custom `--paths` file that structures the monitored scope more narrowly, avoiding the noisy directory or file entirely.

`--exclude` is designed for broad, filename-based exclusions such as log files, temporary files, or editor artefacts that appear across many directories. It is not a substitute for careful path selection.

| Use case | Correct approach |
|----------|-----------------|
| Exclude all `.log` files everywhere | `--exclude "*.log"` |
| Exclude all `.tmp` and `.swp` files | `--exclude "*.tmp" --exclude "*.swp"` |
| Exclude a specific filename everywhere | `--exclude "filename.conf"` |
| Exclude a specific file at a specific path | Use `--paths` to narrow the monitored scope |
| Exclude an entire directory | Use `--paths` and omit that directory |

---

## How It Works

1. **Build the baseline (`--init`)** - scans all monitored paths recursively, computes the SHA-256 hash of every file, and writes the results to the baseline database. An audit log entry is written and a meta checksum of the baseline is stored in `fim_meta.sha256`. The audit log is set to append-only via `chattr +a`.

2. **Verify tamper integrity (`--check`)** - before doing anything else, recomputes the SHA-256 of `baseline.db` and compares it against the stored value in `fim_meta.sha256`. If they don't match, the run aborts immediately with a `TAMPER` alert and exits with code 2.

3. **Scan the filesystem** - rescans all monitored paths using the same method as `--init`, producing a fresh set of hashes.

4. **Compare against baseline** - a single `awk` pass compares the two hash sets and categorises every difference as `ADDED`, `DELETED`, or `MODIFIED`.

5. **Report findings** - each finding is printed to the terminal with colour-coded severity, file metadata (permissions, owner, modification time), and old/new hashes for modified files. Every finding is also written individually to the audit log.

6. **Log to syslog** - a single summary line is sent to syslog via `logger` regardless of whether findings exist. Clean runs log at `auth.info`, findings log at `auth.warning`, and tamper events log at `auth.crit`.

7. **Update meta checksum** - after writing the audit log, the meta checksum of `baseline.db` is refreshed so the next run has an accurate reference.

---

## Monitored Paths

The following paths are monitored by default, aligned with PCI DSS Requirement 11.5 guidance on critical system files:

| Path | Rationale |
|------|-----------|
| `/etc` | System configuration - passwd, sudoers, cron, SSH keys |
| `/bin` | Essential user binaries |
| `/sbin` | Essential system binaries |
| `/usr/bin` | User binaries including compilers and interpreters |
| `/usr/sbin` | System administration binaries |
| `/var/www` | Web root - a primary target for web-based attacks |

To monitor additional or different paths, create a plain text file with one path per line and pass it with `--paths`:

```
# /etc/fim/paths.conf
/etc
/bin
/sbin
/usr/bin
/usr/sbin
/var/www
/opt/myapp/bin
/home/deploy/.ssh
```

```bash
sudo ./fim.sh --check --paths /etc/fim/paths.conf
```

---

## Output

### Terminal Output

Each finding is printed as a colour-coded block:

```
  [MODIFIED] /etc/passwd
             Old: a1b2c3d4e5f6...
             New: f6e5d4c3b2a1...
             Perms: -rw-r--r--  Owner: root  Modified: 2026-03-21 11:42:01

  [ADDED]    /etc/cron.d/backdoor
             New file - not present in baseline

  [DELETED]  /usr/bin/sudo
             File has been removed since baseline
```

| Colour | Change Type |
|--------|-------------|
| 🟡 Yellow | Modified |
| 🟢 Green | Added |
| 🔴 Red | Deleted |

### Audit Log

The audit log at `/var/lib/fim/fim_audit.log` records every event in a structured, append-only format. It contains two types of entries:

**Run summary** - one line per execution:
```
2026-03-21 11:00:01 | host=webserver01 | action=CHECK | added=0 | modified=1 | deleted=0 | total=1 | baseline=/var/lib/fim/baseline.db
```

**Finding detail** - one line per changed file:
```
2026-03-21 11:00:01 | host=webserver01 | action=CHECK | change=MODIFIED | file=/etc/passwd | old=a1b2c3... | new=f6e5d4...
2026-03-21 11:00:01 | host=webserver01 | action=CHECK | change=ADDED | file=/etc/cron.d/backdoor
2026-03-21 11:00:01 | host=webserver01 | action=CHECK | change=DELETED | file=/usr/bin/sudo
```

The audit log is protected at the filesystem level with `chattr +a` (append-only) set automatically on first `--init`. This means even root cannot overwrite or truncate it without first removing the attribute - an action which itself leaves traces.

### Syslog Integration

FIM writes to syslog via `logger` on every run. All entries are tagged with `fim` for easy filtering. On Debian/Ubuntu systems entries appear in `/var/log/auth.log`. On RHEL/CentOS systems they appear in `/var/log/secure`. On systemd-based systems use `journalctl -t fim`.

| Event | Facility/Priority | Status field |
|-------|-------------------|--------------|
| Baseline initialised | `auth.notice` | `action=INIT` |
| Check - no changes | `auth.info` | `status=CLEAN` |
| Check - changes found | `auth.warning` | `status=ALERT` |
| Tamper detected | `auth.crit` | `status=TAMPER` |

**Useful syslog queries:**

```bash
# All FIM events
grep "fim" /var/log/auth.log

# Alerts and tamper events only
grep "fim" /var/log/auth.log | grep -E "ALERT|TAMPER"

# Today's events
grep "fim" /var/log/auth.log | grep "$(date '+%b %e')"

# Search across rotated logs
zgrep "fim" /var/log/auth.log* 2>/dev/null

# systemd
journalctl -t fim --since today
```

### CSV Report

When `--report FILE` is specified, a CSV file is written with one row per finding:

| Column | Description |
|--------|-------------|
| `Change Type` | `ADDED`, `MODIFIED`, or `DELETED` |
| `File Path` | Full path of the affected file |
| `Old Hash` | SHA-256 hash from baseline (MODIFIED only) |
| `New Hash` | SHA-256 hash from current scan (MODIFIED only) |
| `Timestamp` | Date and time of detection |

### Exit Codes

| Code | Meaning |
|------|---------|
| `0` | Clean - no changes detected |
| `1` | Alert - one or more changes detected |
| `2` | Tamper - baseline or meta checksum integrity failure |

---

## Tamper Detection

FIM protects its own evidence files against tampering through a chain of trust:

**`fim_meta.sha256`** stores the SHA-256 hash of `baseline.db`. At the start of every `--check` run, FIM recomputes the baseline hash and compares it against this stored value. If they differ, the run aborts with exit code 2 and a `auth.crit` syslog entry.

**`fim_audit.log`** is protected at the filesystem level with `chattr +a` (append-only), set automatically on first `--init`. Even root cannot overwrite or truncate it without explicitly removing the attribute first.

**The chain:**
```
--init:
  baseline.db  ──────────────► fim_meta.sha256  (sealed)
  fim_audit.log ◄── chattr +a  (append-only)

--check:
  1. Verify fim_meta.sha256  → abort with TAMPER if mismatch
  2. Scan filesystem
  3. Report findings
  4. Append to fim_audit.log
  5. Refresh fim_meta.sha256
```

---

## File Hardening

Proper hardening of FIM's own files is essential. The following recommendations are listed in order of importance.

### `fim_meta.sha256` - the seal

This is the most security-critical file. If an attacker can modify it, they can update it after tampering with the baseline and the tamper check will pass silently.

**Recommended location:** a separate path from the baseline, ideally a read-only mount or a separate partition. Use `META_OVERRIDE` in the script configuration:

```bash
META_OVERRIDE="/mnt/fim-evidence/fim_meta.sha256"
```

**Recommended permissions:**
```bash
chown root:root /mnt/fim-evidence/fim_meta.sha256
chmod 400 /mnt/fim-evidence/fim_meta.sha256
```

**Best options by security level:**

| Option | Protection level | Notes |
|--------|-----------------|-------|
| Read-only mount (`/mnt/fim-evidence`) | Highest | Requires remount to modify - leaves kernel traces |
| Separate partition with restricted permissions | High | Good for most production systems |
| `chattr +i` (immutable) | Medium | Root can remove the attribute, but it requires a deliberate action |
| Same directory as baseline | Lowest | Acceptable for non-critical systems only |

### `fim_audit.log` - the evidence trail

The audit log is automatically set to append-only with `chattr +a` on first `--init`. This is handled by the script. Verify it is active with:

```bash
lsattr /var/lib/fim/fim_audit.log
```

The output should include `a` in the attribute list:
```
-----a------------ /var/lib/fim/fim_audit.log
```

To manually remove and re-apply if needed:
```bash
sudo chattr -a /var/lib/fim/fim_audit.log   # remove append-only
sudo chattr +a /var/lib/fim/fim_audit.log   # re-apply append-only
```

**For maximum protection**, ship audit log entries to a remote syslog server or centralised SIEM in real time. An attacker who compromises the local machine cannot retroactively alter what has already been sent.

### `baseline.db` - the reference

```bash
chown root:root /var/lib/fim/baseline.db
chmod 400 /var/lib/fim/baseline.db
```

The baseline should be readable only by root. Write access is only needed during `--init` runs.

### `fim.sh` - the script itself

```bash
chown root:root /opt/fim/fim.sh
chmod 700 /opt/fim/fim.sh
```

Only root should be able to read or execute the script. This prevents non-privileged users from inspecting the monitoring logic or the paths being watched.

### `/etc/fim/paths.conf` - custom paths file (if used)

```bash
chown root:root /etc/fim/paths.conf
chmod 400 /etc/fim/paths.conf
chattr +i /etc/fim/paths.conf
```

If a custom paths file is used, it should be immutable. An attacker who can modify the paths file can remove critical paths from monitoring scope without touching the baseline.

### Summary table

| File | Owner | Permissions | Extra protection |
|------|-------|-------------|-----------------|
| `fim.sh` | `root:root` | `700` | - |
| `baseline.db` | `root:root` | `400` | - |
| `fim_meta.sha256` | `root:root` | `400` | Read-only mount or separate partition |
| `fim_audit.log` | `root:root` | `600` | `chattr +a` (auto-applied) |
| `paths.conf` | `root:root` | `400` | `chattr +i` |

---

## PCI DSS Compliance

FIM directly addresses **PCI DSS Requirement 11.5** - *Deploy a change-detection mechanism to alert personnel to unauthorised modification of critical system files, configuration files, or content files.*

| PCI DSS Sub-requirement | How FIM addresses it |
|------------------------|----------------------|
| 11.5.1 - Deploy a change-detection mechanism | SHA-256 baseline comparison on every run |
| 11.5.1 - Alert personnel to unauthorised changes | Syslog `auth.warning` + optional email alert |
| 11.5.1 - Cover critical system files | `/etc`, `/bin`, `/sbin`, `/usr/bin`, `/usr/sbin` monitored by default |
| 11.5.1 - Perform comparisons at least weekly | Enforced via cron - see CI/CD section |
| 11.5.2 - Respond to alerts | Exit code 1 enables automated pipeline response |

The audit log provides the tamper-evident record of all checks and findings that an assessor will request as evidence.

---

## CI/CD Integration

### Cron - recommended for PCI DSS compliance

PCI DSS requires checks at least weekly. Daily is recommended:

```cron
# Run daily at 02:00, quiet mode, save dated CSV report
0 2 * * * root /opt/fim/fim.sh --check -q --report /var/log/fim/fim_$(date +\%Y\%m\%d).csv
```

For weekly runs with email alerting:

```cron
0 2 * * 1 root /opt/fim/fim.sh --check -q --email soc@company.com --report /var/log/fim/fim_$(date +\%Y\%m\%d).csv
```

### GitHub Actions

```yaml
- name: File integrity check
  run: |
    chmod +x fim.sh
    sudo ./fim.sh --check --report fim_report.csv

- name: Upload FIM report
  if: always()
  uses: actions/upload-artifact@v3
  with:
    name: fim-report
    path: fim_report.csv
```

### GitLab CI

```yaml
fim-check:
  stage: security
  script:
    - chmod +x fim.sh
    - sudo ./fim.sh --check --report fim_report.csv
  artifacts:
    paths:
      - fim_report.csv
    when: always
```

---

## Limitations

**Regex-based path matching** - the `--exclude` option uses glob patterns, not regular expressions. Complex exclusion rules may require multiple `--exclude` flags.

**No whitelisting** - files that change frequently (e.g. `/etc/resolv.conf`, `/etc/mtab`) will generate alerts on every run. The recommended approach is to exclude noisy paths from the monitored scope via `--paths` rather than whitelisting expected changes after detection. This keeps the detection surface clean and avoids introducing a new attack surface.

**Root requirement** - scanning system paths and writing to `/var/lib/fim/` requires root. Use `--baseline ./fim_baseline.db` for non-root testing.

**Not a replacement for enterprise FIM** - on large or complex infrastructures with hundreds of servers, a centralised solution with a proper management console (AIDE, Tripwire, OSSEC/Wazuh) is more appropriate. FIM is designed for single-server or small-fleet deployments.

**Snapshot-based, not real-time** - FIM detects changes between runs. A file modified and then restored between two runs will not be detected. For real-time detection, consider combining FIM with `auditd` or Linux inotify-based monitoring.

**Local tamper protection only** - `chattr +a` and `fim_meta.sha256` protect against casual tampering but not against a determined attacker with root access who is aware of the tool. For maximum assurance, ship audit log entries and meta checksums to a remote, write-once destination.

---

> **Deployment checklist:**
> 1. Copy `fim.sh` to `/opt/fim/fim.sh` and set `chmod 700`
> 2. Set `META_OVERRIDE` to a secure location outside `/var/lib/fim/`
> 3. Run `sudo ./fim.sh --init` to build the trusted baseline
> 4. Verify `chattr +a` is active on `fim_audit.log`
> 5. Set permissions on all FIM files per the hardening table
> 6. Schedule a daily cron job
> 7. Confirm syslog entries appear in `/var/log/auth.log`
> 8. Run `sudo ./fim.sh --check` and verify a clean run produces `status=CLEAN` in syslog
