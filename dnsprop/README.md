# dnsprop.sh

A smart DNS propagation checker for the terminal. After a DNS record change,
`dnsprop.sh` polls multiple public resolvers in parallel, redraws a live
status dashboard, and exits automatically the moment consensus is reached
across all resolvers.

Part of a sysadmin toolkit series alongside `secrethunt.sh` (shell history
secrets scanner) and `fim.sh` (PCI DSS file integrity monitor).

---

## Features

- Parallel queries across 7 public resolvers (no waiting for each one in turn)
- Live in-place dashboard redrawn each poll round via `tput`
- Three consensus modes: strict, threshold, and expected-value
- Supports A, AAAA, CNAME, MX, TXT, NS, and SOA record types
- Multiple record types checked in a single run
- Optional CSV report with per-resolver latency, TTL, and consensus status
- Syslog integration (`daemon.info` on start, `daemon.notice` on consensus)
- Terminal bell on consensus (suppressible with `--no-bell`)
- Colour-coded status badges, gracefully degraded on non-colour terminals
- Zero dependencies beyond `bash`, `dig`, `tput`, and `logger`

---

## Requirements

| Dependency | Package (Debian/Ubuntu) | Package (RHEL/CentOS) |
|---|---|---|
| `bash` (4.0+) | `bash` | `bash` |
| `dig` | `dnsutils` | `bind-utils` |
| `tput` | `ncurses-bin` | `ncurses` |
| `logger` | `bsdutils` | `util-linux` |

`tput` and `logger` are present on virtually all GNU/Linux systems by default.
If `tput` is missing, colour and in-place redraw are automatically disabled
and the script falls back to plain appended output.

---

## Installation

```bash
# Copy to a directory on your PATH
cp dnsprop.sh /usr/local/bin/dnsprop.sh
chmod +x /usr/local/bin/dnsprop.sh

# Or run directly from the current directory
chmod +x ./dnsprop.sh
./dnsprop.sh --help
```

> **Note.** The shebang is `#!/usr/bin/bash`. If bash lives elsewhere on your
> system, check with `which bash` and update the first line accordingly.

---

## Resolvers

The following resolvers are queried on every poll round:

| Name | IP |
|---|---|
| Google Primary | 8.8.8.8 |
| Google Secondary | 8.8.4.4 |
| Cloudflare Primary | 1.1.1.1 |
| Cloudflare Secondary | 1.0.0.1 |
| OpenDNS Primary | 208.67.222.222 |
| OpenDNS Secondary | 208.67.220.220 |
| Quad9 | 9.9.9.9 |

Run `./dnsprop.sh --list-resolvers` to print this table at any time.

To add or remove resolvers, edit the `RESOLVERS` array near the top of the
script. Each entry follows the format `"Human-readable name|IP"`.

---

## Usage

```
dnsprop.sh [OPTIONS] <domain>
```

### Options

| Flag | Short | Description | Default |
|---|---|---|---|
| `--type <TYPE>` | `-t` | Record type to check. Repeatable. | `A` |
| `--mode <MODE>` | `-m` | Consensus mode: `strict`, `threshold`, `expected` | `strict` |
| `--expected <VALUE>` | `-e` | Expected value (for `expected` mode). Repeatable. | - |
| `--threshold <PCT>` | | Percentage for `threshold` mode (1-100) | `80` |
| `--interval <SEC>` | `-i` | Seconds between poll rounds | `30` |
| `--max-wait <SEC>` | `-w` | Maximum total wait before giving up | `3600` |
| `--dig-timeout <SEC>` | | Per-query `dig` timeout | `5` |
| `--output <FILE>` | `-o` | Write CSV report to file | - |
| `--no-bell` | | Suppress terminal bell on consensus | - |
| `--list-resolvers` | | Print resolver table and exit | - |
| `--help` | `-h` | Show help and exit | - |
| `--version` | | Show version and exit | - |

---

## Consensus Modes

### strict (default)

All resolvers that responded must return identical answer sets. A single
resolver returning a different value blocks consensus. Timed-out resolvers
are excluded from the comparison.

Use this when you need absolute confirmation that a migration is complete
everywhere.

```bash
./dnsprop.sh --type A --mode strict example.com
```

### threshold

The most common answer must appear in at least N% of non-timed-out responses.
Use this when one stubborn regional resolver is lagging and you do not want
to wait for it indefinitely.

```bash
./dnsprop.sh --type A --mode threshold --threshold 80 example.com
```

The dashboard reports the winning value and the percentage at the moment
consensus is reached, e.g. `93.184.216.34 (86% of 7 resolvers)`.

### expected

Every non-timed-out resolver must return the specific value or values you
supply via `--expected`. Use this when you know exactly what the answer
should be and want to verify it precisely, rather than just checking that
everyone agrees with each other.

```bash
./dnsprop.sh --type A --mode expected --expected 203.0.113.42 example.com
```

For multi-value record types such as MX, pass `--expected` multiple times:

```bash
./dnsprop.sh --type MX --mode expected \
    --expected "10 mail.example.com." \
    --expected "20 mail2.example.com." \
    example.com
```

---

## Examples

### Check an A record with default settings

Polls every 30 seconds, gives up after 1 hour, strict consensus.

```bash
./dnsprop.sh example.com
```

### Check an A record with custom timing

Poll every 60 seconds, give up after 2 hours.

```bash
./dnsprop.sh --type A --interval 60 --max-wait 7200 example.com
```

### Check multiple record types at once

Checks A and MX in the same run. Every resolver row appears once per type.
Consensus is only declared when all requested types have reached it.

```bash
./dnsprop.sh --type A --type MX example.com
```

### Verify a specific new IP after a migration

Useful immediately after cutting over a record. The tool will not declare
consensus unless every resolver has picked up the new value, not just any
common value.

```bash
./dnsprop.sh --type A --mode expected --expected 203.0.113.42 \
    --interval 30 --max-wait 3600 example.com
```

### Check a TXT record (e.g. after adding SPF or DKIM)

```bash
./dnsprop.sh --type TXT --mode expected \
    --expected "v=spf1 include:_spf.example.com ~all" \
    --interval 60 --max-wait 7200 \
    example.com
```

### 80% threshold with CSV output

Useful for change-management evidence or postmortems. The CSV captures
every resolver's response on every poll round.

```bash
./dnsprop.sh --type A --mode threshold --threshold 80 \
    --interval 30 --max-wait 1800 \
    --output /var/log/dns_migration_$(date +%Y%m%d_%H%M%S).csv \
    example.com
```

### Suppress the bell (for use in scripts or tmux sessions)

```bash
./dnsprop.sh --type A --no-bell --interval 30 --max-wait 3600 example.com
```

### Run non-interactively and check the exit code

```bash
./dnsprop.sh --type A --no-bell --interval 30 --max-wait 1800 example.com
case $? in
    0) echo "Propagation complete." ;;
    1) echo "Timed out. Not all resolvers agree yet." ;;
    2) echo "Bad arguments." ;;
    3) echo "dig is not installed." ;;
esac
```

---

## Dashboard

The dashboard redraws in-place each poll round. Between rounds it counts
down the seconds to the next poll, updating only the status line so the
display does not flicker.

```
> DNS Propagation Checker  v1.0.0
==============================================================================
  Domain:  example.com
  Types:   A
  Mode:    strict
  Round: 2  Elapsed: 00:00:42  Next poll: 18s

RESOLVER                 IP               TYPE   STATUS       TTL     MS      VALUE
------------------------------------------------------------------------------
Google Primary           8.8.8.8          A      [OK]         299     38      93.184.216.34
Google Secondary         8.8.4.4          A      [OK]         299     41      93.184.216.34
Cloudflare Primary       1.1.1.1          A      [OK]         299     22      93.184.216.34
Cloudflare Secondary     1.0.0.1          A      [OK]         300     19      93.184.216.34
OpenDNS Primary          208.67.222.222   A      [OK]         299     55      93.184.216.34
OpenDNS Secondary        208.67.220.220   A      [OK]         299     58      93.184.216.34
Quad9                    9.9.9.9          A      [!!] TIMEOUT -       5004    -
------------------------------------------------------------------------------
[..] Waiting for consensus...
------------------------------------------------------------------------------
  Press Ctrl-C to abort
```

### Status badges

| Badge | Meaning |
|---|---|
| `[OK]` | Resolver returned a value |
| `[!!] TIMEOUT` | No response within `--dig-timeout` seconds |
| `[!!] NXDOMAIN` | Resolver returned no records for this name |
| `[!=] MISMATCH` | Resolver returned a value that differs from the consensus |
| `[..] PENDING` | Query result not yet received (first render only) |

Timed-out and NXDOMAIN resolvers are excluded from the consensus calculation.
They do not count for or against reaching consensus.

---

## CSV Report

When `--output` is specified, one row is appended per resolver per poll round.
The file is created fresh at startup (existing content is overwritten).

### Columns

| Column | Description |
|---|---|
| `resolver_name` | Human-readable resolver name, e.g. `Google Primary` |
| `resolver_ip` | Resolver IP address |
| `record_type` | Record type queried, e.g. `A`, `MX` |
| `returned_value` | Answer returned. Multiple RRs are joined with ` / `. |
| `ttl` | TTL from the answer section, or `-` for errors |
| `latency_ms` | Round-trip query time in milliseconds |
| `consensus_status` | `YES` if consensus had been reached at this round, else `NO` |

### Example rows

```
resolver_name,resolver_ip,record_type,returned_value,ttl,latency_ms,consensus_status
Google Primary,8.8.8.8,A,"93.184.216.34",299,38,NO
Cloudflare Primary,1.1.1.1,A,"93.184.216.34",299,22,NO
Quad9,9.9.9.9,A,"TIMEOUT",-,5004,NO
Google Primary,8.8.8.8,A,"93.184.216.34",299,35,YES
Cloudflare Primary,1.1.1.1,A,"93.184.216.34",299,21,YES
```

### Analysing the CSV

Count responses per unique value to spot resolvers still serving stale data:

```bash
awk -F',' 'NR>1 {gsub(/"/, "", $4); print $4}' report.csv | sort | uniq -c | sort -rn
```

Find the round at which each resolver first returned the new value:

```bash
awk -F',' 'NR>1 {print $1, $4}' report.csv | grep "203.0.113.42"
```

Identify slow resolvers by average latency:

```bash
awk -F',' 'NR>1 {sum[$1]+=$6; count[$1]++}
    END {for (r in sum) printf "%s avg %dms\n", r, sum[r]/count[r]}' report.csv \
    | sort -t' ' -k3 -n
```

---

## Syslog

All significant events are written to syslog under the tag `dnsprop`.

| Event | Priority |
|---|---|
| Script started | `daemon.info` |
| Consensus reached | `daemon.notice` |
| Max-wait exceeded | `daemon.warning` |

### Reading syslog entries

```bash
# systemd systems
journalctl -t dnsprop

# Classic syslog
grep dnsprop /var/log/syslog
grep dnsprop /var/log/messages
```

### Example syslog output

```
Mar 29 14:01:12 host dnsprop[3821]: dnsprop started: domain=example.com types=A mode=strict interval=30s max-wait=3600s
Mar 29 14:02:18 host dnsprop[3821]: Consensus reached: domain=example.com types=A value=93.184.216.34
```

---

## Exit Codes

| Code | Meaning |
|---|---|
| `0` | Consensus reached within `--max-wait` |
| `1` | `--max-wait` exceeded without consensus |
| `2` | Bad arguments or configuration error |
| `3` | `dig` not found |

---

## Scripting and Automation

Because the exit codes are meaningful, `dnsprop.sh` can be embedded directly
in deployment pipelines or change-management scripts.

### Block a deployment until DNS has propagated

```bash
#!/usr/bin/bash

NEW_IP="203.0.113.42"
DOMAIN="example.com"

echo "Waiting for DNS propagation..."
if ./dnsprop.sh \
    --type A \
    --mode expected \
    --expected "$NEW_IP" \
    --interval 60 \
    --max-wait 7200 \
    --no-bell \
    --output "/var/log/dns_${DOMAIN}_$(date +%Y%m%d_%H%M%S).csv" \
    "$DOMAIN"; then
    echo "DNS propagated. Proceeding with deployment."
    # ... rest of deployment
else
    echo "DNS did not propagate within 2 hours. Aborting." >&2
    exit 1
fi
```

### Run from cron and log to syslog only

Since syslog integration is built in, you can run the script unattended and
rely on `journalctl` or log aggregation for notification.

```bash
# /etc/cron.d/dns-check
0 * * * * root /usr/local/bin/dnsprop.sh --type A --no-bell \
    --interval 60 --max-wait 3540 example.com >/dev/null 2>&1
```

---

## Locale and Terminal Notes

The script uses only ASCII characters in its output. It will display correctly
on any locale and any terminal emulator, including basic SSH clients.

Colour output requires a terminal that reports at least 8 colours via
`tput colors`. If colour is unavailable, the script runs normally with plain
text output and no in-place redraw.

The in-place dashboard requires `tput` for cursor positioning. Without it,
output is appended line by line instead.

---

## Limitations

- `date +%s%3N` (millisecond timestamps for latency) requires GNU `date`.
  On macOS, install `coreutils` via Homebrew and use `gdate`, or accept that
  latency will not be measured.
- The script is designed for GNU/Linux. It has not been tested on BSD or macOS.
- Resolver addresses are hardcoded. There is no runtime flag to add resolvers
  without editing the script.
- The threshold mode tally uses an O(n^2) loop. With 7 resolvers this is
  49 iterations maximum and has no practical impact on performance.

---

## License

MIT. See `LICENSE` for details.
