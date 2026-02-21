#!/usr/bin/env bash
# =============================================================================
# check_ssl.sh — Validate SSL certificates for a list of domains
#
# Usage:
#   ./check_ssl.sh domains.txt [OPTIONS]
#   ./check_ssl.sh -d DOMAIN   [OPTIONS]
#
# Options:
#   -d DOMAIN        Check a single domain directly (ignores domain file)
#   -p PORT          Port to connect on (default: 443)
#   -w DAYS          Warn if cert expires within DAYS days (default: 30)
#   -t TIMEOUT       Connection timeout in seconds (default: 10)
#   -o FILE          Save CSV report to FILE
#   -q               Quiet mode — only show warnings/errors
#   -h               Show this help message
#
# domains.txt format:
#   One domain per line. Lines starting with # are treated as comments.
#   Optionally specify a custom port per domain: example.com:8443
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
PORT=443
WARN_DAYS=30
TIMEOUT=10
OUTPUT_FILE=""
QUIET=false
SINGLE_DOMAIN=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"
YELLOW="\033[0;33m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
BOLD="\033[1m"
RESET="\033[0m"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^# ===/{ /^# ===/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

log()   { echo -e "$*"; }
info()  { $QUIET || log "${CYAN}[INFO]${RESET}  $*"; }
ok()    { $QUIET || log "${GREEN}[OK]${RESET}    $*"; }
warn()  { log "${YELLOW}[WARN]${RESET}  $*"; }
error() { log "${RED}[ERROR]${RESET} $*"; }

require_cmd() {
  command -v "$1" &>/dev/null || { error "Required command not found: $1"; exit 1; }
}

# ── Date helper (cross-platform: macOS & Linux) ───────────────────────────────
days_until() {
  local expiry_str="$1"
  local expiry_epoch now_epoch
  if date --version &>/dev/null 2>&1; then
    expiry_epoch=$(date -d "$expiry_str" +%s 2>/dev/null)
  else
    expiry_epoch=$(date -j -f "%b %d %T %Y %Z" "$expiry_str" +%s 2>/dev/null)
  fi
  now_epoch=$(date +%s)
  echo $(( (expiry_epoch - now_epoch) / 86400 ))
}

# ── Check a single domain and print results ───────────────────────────────────
check_domain() {
  local domain="$1"
  local port="$2"

  (( total++ )) || true

  cert_info=$(echo | timeout "$TIMEOUT" openssl s_client \
    -connect "${domain}:${port}" \
    -servername "$domain" \
    2>/dev/null | openssl x509 -noout -dates -issuer -subject 2>/dev/null || true)

  if [[ -z "$cert_info" ]]; then
    error "${BOLD}${domain}:${port}${RESET} — Could not retrieve certificate"
    (( failed++ )) || true
    [[ -n "$OUTPUT_FILE" ]] && echo "${domain},${port},UNREACHABLE,,,," >> "$OUTPUT_FILE"
    return
  fi

  local not_after not_before issuer subject days status msg
  not_after=$(echo "$cert_info"  | grep 'notAfter='  | cut -d= -f2)
  not_before=$(echo "$cert_info" | grep 'notBefore=' | cut -d= -f2)
  issuer=$(echo "$cert_info"     | grep '^issuer='   | sed 's/^issuer=//')
  subject=$(echo "$cert_info"    | grep '^subject='  | sed 's/^subject=//')

  days=$(days_until "$not_after")

  if [[ "$days" -lt 0 ]]; then
    status="EXPIRED"
    msg="${RED}EXPIRED${RESET} (${days#-} days ago — ${not_after})"
    (( failed++ )) || true
  elif [[ "$days" -lt "$WARN_DAYS" ]]; then
    status="EXPIRING_SOON"
    msg="${YELLOW}EXPIRING SOON${RESET} (${days} days left — ${not_after})"
    (( warned++ )) || true
  else
    status="VALID"
    msg="${GREEN}VALID${RESET} (${days} days left — ${not_after})"
    (( passed++ )) || true
  fi

  log "${BOLD}${domain}:${port}${RESET}"
  log "  Status  : ${msg}"
  $QUIET || log "  Issuer  : ${issuer}"
  $QUIET || log "  Subject : ${subject}"
  $QUIET || log "  Valid from: ${not_before}"
  log ""

  if [[ -n "$OUTPUT_FILE" ]]; then
    echo "${domain},${port},${status},${not_after},${days},\"${issuer}\",\"${subject}\"" >> "$OUTPUT_FILE"
  fi
}

# ── Argument parsing ──────────────────────────────────────────────────────────
# Handle -h/--help before any other validation
for arg in "$@"; do
  [[ "$arg" == "-h" || "$arg" == "--help" ]] && usage
done

[[ $# -eq 0 ]] && { error "No domain file or -d option specified."; echo "Usage: $0 <domains.txt> [OPTIONS]  |  $0 -d DOMAIN [OPTIONS]"; exit 1; }

# If first arg is not a flag, treat it as the domain file
DOMAIN_FILE=""
if [[ "$1" != -* ]]; then
  DOMAIN_FILE="$1"; shift
fi

while getopts ":d:p:w:t:o:qh" opt; do
  case $opt in
    d) SINGLE_DOMAIN="$OPTARG" ;;
    p) PORT="$OPTARG" ;;
    w) WARN_DAYS="$OPTARG" ;;
    t) TIMEOUT="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    q) QUIET=true ;;
    h) usage ;;
    :) error "Option -$OPTARG requires an argument."; exit 1 ;;
    \?) error "Unknown option: -$OPTARG"; exit 1 ;;
  esac
done

# Validate: need either -d or a domain file
if [[ -z "$SINGLE_DOMAIN" && -z "$DOMAIN_FILE" ]]; then
  error "No domain file or -d option specified."
  echo "Usage: $0 <domains.txt> [OPTIONS]  |  $0 -d DOMAIN [OPTIONS]"
  exit 1
fi

# ── Pre-flight checks ─────────────────────────────────────────────────────────
require_cmd openssl
require_cmd date

# ── Counters ──────────────────────────────────────────────────────────────────
total=0; passed=0; warned=0; failed=0

# ── CSV header ────────────────────────────────────────────────────────────────
if [[ -n "$OUTPUT_FILE" ]]; then
  echo "Domain,Port,Status,Expiry Date,Days Remaining,Issuer,Subject" > "$OUTPUT_FILE"
fi

# ── Interactive single-domain mode ────────────────────────────────────────────
if [[ -n "$SINGLE_DOMAIN" ]]; then
  # Support domain:port syntax in -d value
  if [[ "$SINGLE_DOMAIN" == *:* ]]; then
    domain="${SINGLE_DOMAIN%%:*}"
    port="${SINGLE_DOMAIN##*:}"
  else
    domain="$SINGLE_DOMAIN"
    port="$PORT"
  fi

  log ""
  log "${BOLD}SSL Certificate Checker${RESET} — Single domain mode"
  log "Domain      : ${domain}:${port}"
  log "Warn before : ${WARN_DAYS} days"
  log "$(printf '─%.0s' {1..60})"
  log ""

  check_domain "$domain" "$port"

  # ── Interactive loop ──────────────────────────────────────────────────────
  while true; do
    log "$(printf '─%.0s' {1..60})"
    echo -en "${CYAN}Enter another domain to check (or 'q' to quit): ${RESET}"
    read -r input
    [[ -z "$input" || "$input" == "q" || "$input" == "quit" ]] && break

    if [[ "$input" == *:* ]]; then
      domain="${input%%:*}"
      port="${input##*:}"
    else
      domain="$input"
      port="$PORT"
    fi

    log ""
    check_domain "$domain" "$port"
  done

# ── File mode ─────────────────────────────────────────────────────────────────
else
  [[ -f "$DOMAIN_FILE" ]] || { error "Domain file not found: $DOMAIN_FILE"; exit 1; }

  log ""
  log "${BOLD}SSL Certificate Checker${RESET}"
  log "Domain file : $DOMAIN_FILE"
  log "Warn before : ${WARN_DAYS} days"
  log "$(printf '─%.0s' {1..60})"
  log ""

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" == *:* ]]; then
      domain="${line%%:*}"
      port="${line##*:}"
    else
      domain="$line"
      port="$PORT"
    fi

    check_domain "$domain" "$port"
  done < "$DOMAIN_FILE"
fi

# ── Summary ───────────────────────────────────────────────────────────────────
log "$(printf '─%.0s' {1..60})"
log "${BOLD}Summary${RESET}  —  Total: ${total}  ✅ Valid: ${passed}  ⚠️  Expiring: ${warned}  ❌ Failed/Expired: ${failed}"
[[ -n "$OUTPUT_FILE" ]] && log "Report saved to: ${OUTPUT_FILE}"
log ""

# Exit with non-zero if any cert failed or expired
[[ $((failed + warned)) -eq 0 ]] && exit 0 || exit 1
