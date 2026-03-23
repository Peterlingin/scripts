#!/usr/bin/env bash
# =============================================================================
# fim.sh — File Integrity Monitor
#
# A lightweight, zero-dependency file integrity monitor aligned with
# PCI DSS Requirement 11.5. Detects added, deleted, and modified files
# by comparing SHA-256 hashes against a stored baseline.
#
# Usage:
#   ./fim.sh [OPTIONS]
#
# Options:
#   --init           Create or rebuild the baseline database
#   --check          Compare current state against baseline (default)
#   --paths FILE     Load custom paths from a file (one path per line)
#   --baseline FILE  Use a custom baseline file (default: /var/lib/fim/baseline.db)
#   --report FILE    Save findings to a CSV report file
#   --email ADDRESS  Send alert email on findings (requires mail command)
#   --exclude GLOB   Exclude files matching GLOB pattern (repeatable)
#   -q               Quiet mode — suppress banner and info, show findings only
#   -h               Show this help message
#
# Default monitored paths:
#   /etc, /bin, /sbin, /usr/bin, /usr/sbin, /var/www
#
# Baseline file:
#   Stored at /var/lib/fim/baseline.db by default (requires root).
#   Use --baseline ./fim_baseline.db for non-root usage.
#
# PCI DSS:
#   Addresses Requirement 11.5 — Deploy a change-detection mechanism to
#   alert personnel to unauthorized modification of critical system files.
# =============================================================================

set -euo pipefail

# ── Configuration ────────────────────────────────────────────────────────────
# Set META_OVERRIDE to store fim_meta.sha256 in a separate, safe location.
# Recommended for production: a read-only mount, a separate partition, or a
# remote path. Leave empty to store alongside the baseline file (less secure).
META_OVERRIDE=""   # e.g. "/mnt/fim-evidence/fim_meta.sha256"

# ── Defaults ──────────────────────────────────────────────────────────────────
MODE="check"
BASELINE_FILE="/var/lib/fim/baseline.db"
REPORT_FILE=""
EMAIL_ADDRESS=""
QUIET=false
CUSTOM_PATHS_FILE=""
declare -a EXCLUDE_GLOBS=()

# Derived paths — resolved after argument parsing
META_FILE=""   # set by resolve_paths()
AUDIT_LOG=""   # set by resolve_paths()

# ── Default monitored paths (PCI DSS Req. 11.5 aligned) ──────────────────────
declare -a DEFAULT_PATHS=(
  "/etc"
  "/bin"
  "/sbin"
  "/usr/bin"
  "/usr/sbin"
  "/var/www"
)

# ── Colours ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"
GREEN="\033[0;32m"
YELLOW="\033[1;33m"
CYAN="\033[0;36m"
GRAY="\033[0;90m"
BOLD="\033[1m"
RESET="\033[0m"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^# ===/{ /^# ===/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

log()     { echo -e "$*"; }
info()    { $QUIET || echo -e "${CYAN}[INFO]${RESET}  $*"; }
success() { $QUIET || echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

require_cmd() {
  command -v "$1" &>/dev/null || { error "Required command not found: $1"; exit 1; }
}

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  [[ "$arg" == "-h" || "$arg" == "--help" ]] && usage
done

while [[ $# -gt 0 ]]; do
  case "$1" in
    --init)          MODE="init" ;;
    --check)         MODE="check" ;;
    --baseline)      BASELINE_FILE="$2"; shift ;;
    --paths)         CUSTOM_PATHS_FILE="$2"; shift ;;
    --report)        REPORT_FILE="$2"; shift ;;
    --email)         EMAIL_ADDRESS="$2"; shift ;;
    --exclude)       EXCLUDE_GLOBS+=("$2"); shift ;;
    -q)              QUIET=true ;;
    -h|--help)       usage ;;
    *) error "Unknown option: $1"; exit 1 ;;
  esac
  shift
done

# ── Pre-flight checks ─────────────────────────────────────────────────────────
require_cmd sha256sum
require_cmd find
require_cmd stat
[[ -n "$EMAIL_ADDRESS" ]] && require_cmd mail

# ── Build monitored path list ─────────────────────────────────────────────────
declare -a MONITOR_PATHS=()
if [[ -n "$CUSTOM_PATHS_FILE" ]]; then
  [[ -f "$CUSTOM_PATHS_FILE" ]] || { error "Paths file not found: $CUSTOM_PATHS_FILE"; exit 1; }
  while IFS= read -r p || [[ -n "$p" ]]; do
    p="${p%$'\r'}"
    [[ -z "$p" || "$p" == \#* ]] && continue
    MONITOR_PATHS+=("$p")
  done < "$CUSTOM_PATHS_FILE"
else
  MONITOR_PATHS=("${DEFAULT_PATHS[@]}")
fi

# Filter to paths that actually exist
declare -a ACTIVE_PATHS=()
for p in "${MONITOR_PATHS[@]}"; do
  [[ -e "$p" ]] && ACTIVE_PATHS+=("$p") || warn "Path not found, skipping: $p"
done

[[ ${#ACTIVE_PATHS[@]} -eq 0 ]] && { error "No valid paths to monitor."; exit 1; }

# ── Timestamp ─────────────────────────────────────────────────────────────────
now() { date '+%Y-%m-%d %H:%M:%S'; }

# ── Resolve derived paths (called after BASELINE_FILE is finalised) ───────────
resolve_paths() {
  local dir
  dir="$(dirname "$BASELINE_FILE")"
  AUDIT_LOG="${dir}/fim_audit.log"
  if [[ -n "$META_OVERRIDE" ]]; then
    META_FILE="$META_OVERRIDE"
  else
    META_FILE="${dir}/fim_meta.sha256"
  fi
}

# ── Update meta checksum file ─────────────────────────────────────────────────
# Stores SHA-256 of the baseline only. The audit log is protected separately
# by filesystem-level append-only attribute (chattr +a) and must not be hashed
# here since it legitimately grows on every run.
update_meta() {
  local tmp
  tmp=$(mktemp)
  [[ -f "$BASELINE_FILE" ]] && sha256sum "$BASELINE_FILE" >> "$tmp"
  mv "$tmp" "$META_FILE"
  info "Meta checksum updated: $META_FILE"
}

# ── Verify meta checksum file ─────────────────────────────────────────────────
# Called at the start of --check. Aborts if tampering is detected.
verify_meta() {
  if [[ ! -f "$META_FILE" ]]; then
    warn "Meta checksum file not found ($META_FILE) — skipping tamper check."
    warn "Run --init to establish a trusted checksum baseline."
    return
  fi

  local tampered=false
  while IFS= read -r line; do
    expected_hash="${line%% *}"
    filepath="${line#*  }"
    if [[ ! -f "$filepath" ]]; then
      warn "Monitored meta file missing: $filepath"
      tampered=true
      continue
    fi
    actual_hash=$(sha256sum "$filepath" | awk '{print $1}')
    if [[ "$actual_hash" != "$expected_hash" ]]; then
      error "TAMPER DETECTED: $filepath"
      error "  Expected : $expected_hash"
      error "  Actual   : $actual_hash"
      tampered=true
    fi
  done < "$META_FILE"

  if $tampered; then
    error "$(printf '─%.0s' {1..60})"
    error "One or more FIM evidence files have been tampered with."
    error "Do NOT trust this run. Rebuild the baseline with --init"
    error "from a known-good state."
    error "$(printf '─%.0s' {1..60})"
    logger -p auth.crit -t fim "host=$(hostname) action=CHECK status=TAMPER baseline=$BASELINE_FILE" 2>/dev/null || true
    exit 2
  fi

  $QUIET || success "Tamper check passed — baseline integrity verified."
}

# ── Apply append-only attribute to audit log (Linux only) ─────────────────────
set_append_only() {
  if command -v chattr &>/dev/null; then
    chattr +a "$AUDIT_LOG" 2>/dev/null       && info "Audit log set to append-only (chattr +a): $AUDIT_LOG"       || warn "Could not set append-only on audit log (chattr failed — root required?)"
  else
    warn "chattr not available — append-only protection skipped (non-Linux system?)"
  fi
}

# ── Ensure baseline directory exists ─────────────────────────────────────────
BASELINE_DIR="$(dirname "$BASELINE_FILE")"
if [[ ! -d "$BASELINE_DIR" ]]; then
  mkdir -p "$BASELINE_DIR" 2>/dev/null || {
    error "Cannot create baseline directory: $BASELINE_DIR"
    error "Try --baseline ./fim_baseline.db for non-root usage."
    exit 1
  }
fi

# ── Resolve derived file paths ───────────────────────────────────────────────
resolve_paths

# ── Build find exclusion arguments ───────────────────────────────────────────
declare -a FIND_EXCLUDES=()
for glob in "${EXCLUDE_GLOBS[@]}"; do
  FIND_EXCLUDES+=( "!" "-name" "$glob" )
done

# ── Scan all monitored paths and emit "hash  path" lines ─────────────────────
scan_files() {
  local path
  for path in "${ACTIVE_PATHS[@]}"; do
    if [[ -f "$path" ]]; then
      # Single file
      sha256sum "$path" 2>/dev/null || true
    elif [[ -d "$path" ]]; then
      find "$path" -type f "${FIND_EXCLUDES[@]}" -print0 2>/dev/null \
        | sort -z \
        | xargs -0 sha256sum 2>/dev/null || true
    fi
  done
}

# ═════════════════════════════════════════════════════════════════════════════
# INIT MODE — build baseline
# ═════════════════════════════════════════════════════════════════════════════
if [[ "$MODE" == "init" ]]; then
  if ! $QUIET; then
    log ""
    log "${BOLD}🛡  File Integrity Monitor — Baseline Init${RESET}"
    log "Baseline file : $BASELINE_FILE"
    log "Monitored     : ${ACTIVE_PATHS[*]}"
    log "$(printf '─%.0s' {1..60})"
    log ""
  fi

  # Backup existing baseline
  if [[ -f "$BASELINE_FILE" ]]; then
    cp "$BASELINE_FILE" "${BASELINE_FILE}.bak"
    info "Previous baseline backed up to ${BASELINE_FILE}.bak"
  fi

  info "Scanning files…"
  tmp_scan=$(mktemp)
  scan_files > "$tmp_scan"

  file_count=$(wc -l < "$tmp_scan" | tr -d ' ')

  # Write baseline with header
  {
    echo "# FIM Baseline — generated $(now)"
    echo "# Paths: ${ACTIVE_PATHS[*]}"
    echo "# Files: $file_count"
    cat "$tmp_scan"
  } > "$BASELINE_FILE"

  rm -f "$tmp_scan"

  log ""
  success "Baseline created: ${file_count} files hashed."
  log "  ${GRAY}${BASELINE_FILE}${RESET}"
  log ""

  # ── Audit log entry for init ───────────────────────────────────────────────
  # Apply append-only on first creation
  if [[ ! -f "$AUDIT_LOG" ]]; then
    touch "$AUDIT_LOG" 2>/dev/null || true
    set_append_only
  fi
  ( echo "$(now) | host=$(hostname) | action=INIT | files=$file_count | baseline=$BASELINE_FILE" >> "$AUDIT_LOG" ) 2>/dev/null || true

  # ── Syslog entry for baseline init ────────────────────────────────────────
  logger -p auth.notice -t fim "host=$(hostname) action=INIT files=$file_count baseline=$BASELINE_FILE" 2>/dev/null || true

  # ── Update meta checksum after baseline + audit log are written ────────────
  update_meta

  exit 0
fi

# ═════════════════════════════════════════════════════════════════════════════
# CHECK MODE — compare against baseline
# ═════════════════════════════════════════════════════════════════════════════

# Auto-create baseline if missing
if [[ ! -f "$BASELINE_FILE" ]]; then
  warn "No baseline found at $BASELINE_FILE — creating one now."
  warn "Run --init explicitly to acknowledge the current state as trusted."
  log ""
  tmp_scan=$(mktemp)
  scan_files > "$tmp_scan"
  file_count=$(wc -l < "$tmp_scan" | tr -d ' ')
  {
    echo "# FIM Baseline — auto-generated $(now)"
    echo "# Paths: ${ACTIVE_PATHS[*]}"
    echo "# Files: $file_count"
    cat "$tmp_scan"
  } > "$BASELINE_FILE"
  rm -f "$tmp_scan"
  success "Baseline auto-created with ${file_count} files. Re-run to check integrity."
  log ""
  exit 0
fi

# ── Tamper verification ──────────────────────────────────────────────────────
verify_meta

# ── Banner ────────────────────────────────────────────────────────────────────
if ! $QUIET; then
  log ""
  log "${BOLD}🛡  File Integrity Monitor — Integrity Check${RESET}"
  log "Baseline file : $BASELINE_FILE"
  log "Monitored     : ${ACTIVE_PATHS[*]}"
  log "Timestamp     : $(now)"
  log "$(printf '─%.0s' {1..60})"
  log ""
fi

# ── Scan current state ────────────────────────────────────────────────────────
info "Scanning files…"
current_scan=$(mktemp)
scan_files > "$current_scan"

# ── Load baseline (strip comment lines) ──────────────────────────────────────
baseline_clean=$(mktemp)
grep -v '^#' "$BASELINE_FILE" > "$baseline_clean"

# ── Build lookup maps using awk (single pass, no per-line subshells) ──────────
# Compare baseline vs current — produces tagged output lines:
#   MODIFIED <file>  <old_hash>  <new_hash>
#   ADDED    <file>
#   DELETED  <file>
diff_output=$(awk '
  NR == FNR {
    # Load baseline: hash is $1, path is rest of line
    hash = $1
    $1 = ""
    sub(/^[[:space:]]+/, "")
    baseline_hash[$0] = hash
    baseline_seen[$0]  = 1
    next
  }
  {
    hash = $1
    $1 = ""
    sub(/^[[:space:]]+/, "")
    path = $0
    current_seen[path] = 1
    if (path in baseline_seen) {
      if (baseline_hash[path] != hash) {
        print "MODIFIED\t" path "\t" baseline_hash[path] "\t" hash
      }
    } else {
      print "ADDED\t" path
    }
  }
  END {
    for (path in baseline_seen) {
      if (!(path in current_seen)) {
        print "DELETED\t" path
      }
    }
  }
' "$baseline_clean" "$current_scan")

rm -f "$current_scan" "$baseline_clean"

# ── Parse and display findings ────────────────────────────────────────────────
added=0; modified=0; deleted=0
declare -a report_rows=()

diff_tmp=$(mktemp)
echo "$diff_output" > "$diff_tmp"

if [[ -n "$diff_output" ]]; then
  while IFS=$'\t' read -r change_type filepath old_hash new_hash; do
    case "$change_type" in
      ADDED)
        (( added++ )) || true
        log "  ${GREEN}[ADDED]   ${RESET} ${filepath}"
        $QUIET || log "            ${GRAY}New file — not present in baseline${RESET}"
        log ""
        report_rows+=("ADDED,\"${filepath}\",,,$(now)")
        ( echo "$(now) | host=$(hostname) | action=CHECK | change=ADDED | file=${filepath}" >> "$AUDIT_LOG" ) 2>/dev/null || true
        ;;
      DELETED)
        (( deleted++ )) || true
        log "  ${RED}[DELETED] ${RESET} ${filepath}"
        $QUIET || log "            ${GRAY}File has been removed since baseline${RESET}"
        log ""
        report_rows+=("DELETED,\"${filepath}\",,,$(now)")
        ( echo "$(now) | host=$(hostname) | action=CHECK | change=DELETED | file=${filepath}" >> "$AUDIT_LOG" ) 2>/dev/null || true
        ;;
      MODIFIED)
        (( modified++ )) || true
        log "  ${YELLOW}[MODIFIED]${RESET} ${filepath}"
        if ! $QUIET; then
          log "            ${GRAY}Old: ${old_hash}${RESET}"
          log "            ${GRAY}New: ${new_hash}${RESET}"
          # File metadata
          if [[ -f "$filepath" ]]; then
            perms=$(stat -c '%A' "$filepath" 2>/dev/null || stat -f '%Sp' "$filepath" 2>/dev/null || echo "N/A")
            owner=$(stat -c '%U' "$filepath" 2>/dev/null || stat -f '%Su' "$filepath" 2>/dev/null || echo "N/A")
            mtime=$(stat -c '%y' "$filepath" 2>/dev/null || stat -f '%Sm' "$filepath" 2>/dev/null || echo "N/A")
            log "            ${GRAY}Perms: ${perms}  Owner: ${owner}  Modified: ${mtime}${RESET}"
          fi
        fi
        log ""
        report_rows+=("MODIFIED,\"${filepath}\",\"${old_hash}\",\"${new_hash}\",$(now)")
        ( echo "$(now) | host=$(hostname) | action=CHECK | change=MODIFIED | file=${filepath} | old=${old_hash} | new=${new_hash}" >> "$AUDIT_LOG" ) 2>/dev/null || true
        ;;
    esac
  done < "$diff_tmp"
  rm -f "$diff_tmp"
else
  success "No changes detected. All files match the baseline."
  log ""
fi

total_findings=$(( added + modified + deleted ))

# ── CSV Report ────────────────────────────────────────────────────────────────
if [[ -n "$REPORT_FILE" && $total_findings -gt 0 ]]; then
  {
    echo "Change Type,File Path,Old Hash,New Hash,Timestamp"
    for row in "${report_rows[@]}"; do
      echo "$row"
    done
  } > "$REPORT_FILE"
  info "Report saved to: $REPORT_FILE"
fi

# ── Email alert ───────────────────────────────────────────────────────────────
if [[ -n "$EMAIL_ADDRESS" && $total_findings -gt 0 ]]; then
  {
    echo "FIM Alert — $(now)"
    echo ""
    echo "Host     : $(hostname)"
    echo "Baseline : $BASELINE_FILE"
    echo ""
    echo "Summary"
    echo "  Added    : $added"
    echo "  Modified : $modified"
    echo "  Deleted  : $deleted"
    echo ""
    echo "Findings"
    for row in "${report_rows[@]}"; do
      echo "  ${row//,/ | }"
    done
    echo ""
    echo "-- fim.sh"
  } | mail -s "[FIM ALERT] $(hostname) — ${total_findings} change(s) detected" "$EMAIL_ADDRESS" \
    && info "Alert sent to $EMAIL_ADDRESS" \
    || warn "Failed to send email alert."
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "$(printf '─%.0s' {1..60})"
log "${BOLD}Summary${RESET}  —  $(now)"
log "  ${GREEN}Added   : ${added}${RESET}"
log "  ${YELLOW}Modified: ${modified}${RESET}"
log "  ${RED}Deleted : ${deleted}${RESET}"
log "  Total   : ${total_findings}"
log ""

# ── Append to audit log ──────────────────────────────────────────────────────
( echo "$(now) | host=$(hostname) | action=CHECK | added=$added | modified=$modified | deleted=$deleted | total=$total_findings | baseline=$BASELINE_FILE" >> "$AUDIT_LOG" ) 2>/dev/null || true

# ── Syslog entry — one line per run ──────────────────────────────────────────
if [[ $total_findings -eq 0 ]]; then
  logger -p auth.info  -t fim "host=$(hostname) action=CHECK status=CLEAN  added=0 modified=0 deleted=0 baseline=$BASELINE_FILE" 2>/dev/null || true
else
  logger -p auth.warning -t fim "host=$(hostname) action=CHECK status=ALERT added=$added modified=$modified deleted=$deleted total=$total_findings baseline=$BASELINE_FILE" 2>/dev/null || true
fi

# ── Update meta checksum after audit log is written ──────────────────────────
update_meta

[[ $total_findings -eq 0 ]] && exit 0 || exit 1
