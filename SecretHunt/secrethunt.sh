#!/usr/bin/env bash
# =============================================================================
# secrethunt.sh — Hunt for leaked secrets & credentials in shell history files
#
# Usage:
#   ./secrethunt.sh [OPTIONS]
#
# Options:
#   -f FILE          Scan a specific history file instead of defaults
#   -o FILE          Save CSV report to FILE
#   -s SEVERITY      Minimum severity to report: low, medium, high (default: low)
#   -q               Quiet mode — only show findings, no banner or summary
#   -h               Show this help message
#
# Scanned by default:
#   ~/.bash_history, ~/.zsh_history, ~/.local/share/fish/fish_history
#
# Severity levels:
#   high    — Known secret formats (AWS keys, GitHub tokens, private keys...)
#   medium  — Generic key/password assignments with suspicious values
#   low     — Suspicious patterns (token=, secret=, passwd= with any value)
# =============================================================================

set -euo pipefail

# ── Defaults ──────────────────────────────────────────────────────────────────
OUTPUT_FILE=""
MIN_SEVERITY="low"
QUIET=false
CUSTOM_FILE=""

# ── Colours ───────────────────────────────────────────────────────────────────
RED="\033[0;31m"
ORANGE="\033[0;33m"
YELLOW="\033[1;33m"
GREEN="\033[0;32m"
CYAN="\033[0;36m"
GRAY="\033[0;90m"
BOLD="\033[1m"
RESET="\033[0m"

# ── Helpers ───────────────────────────────────────────────────────────────────
usage() {
  sed -n '2,/^# ===/{ /^# ===/d; s/^# \{0,1\}//; p }' "$0"
  exit 0
}

log()   { echo -e "$*"; }
error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }

# ── Severity filter — pure bash, no subshells ─────────────────────────────────
# Returns 0 (pass) or 1 (skip) based on MIN_SEVERITY
passes_filter() {
  # $1 = pattern severity, MIN_SEVERITY = global threshold
  # Rank: high=3 medium=2 low=1
  local ps ms
  case "$1"            in high) ps=3;; medium) ps=2;; *) ps=1;; esac
  case "$MIN_SEVERITY" in high) ms=3;; medium) ms=2;; *) ms=1;; esac
  (( ps >= ms ))
}

# ── Entropy — computed inline by awk, called once per match only ──────────────
entropy() {
  awk -v s="$1" 'BEGIN {
    n = split(s, a, "")
    for (i = 1; i <= n; i++) freq[a[i]]++
    for (c in freq) { p = freq[c]/n; e -= p * log(p)/log(2) }
    printf "%.2f", e
  }'
}

# ── Argument parsing ──────────────────────────────────────────────────────────
for arg in "$@"; do
  [[ "$arg" == "-h" || "$arg" == "--help" ]] && usage
done

while getopts ":f:o:s:qh" opt; do
  case $opt in
    f) CUSTOM_FILE="$OPTARG" ;;
    o) OUTPUT_FILE="$OPTARG" ;;
    s) MIN_SEVERITY="$OPTARG" ;;
    q) QUIET=true ;;
    h) usage ;;
    :) error "Option -$OPTARG requires an argument."; exit 1 ;;
    \?) error "Unknown option: -$OPTARG"; exit 1 ;;
  esac
done

case "$MIN_SEVERITY" in
  low|medium|high) ;;
  *) error "Invalid severity '$MIN_SEVERITY'. Use: low, medium, high"; exit 1 ;;
esac

# ── Build list of history files ───────────────────────────────────────────────
declare -a HISTORY_FILES=()
if [[ -n "$CUSTOM_FILE" ]]; then
  [[ -f "$CUSTOM_FILE" ]] || { error "File not found: $CUSTOM_FILE"; exit 1; }
  HISTORY_FILES+=("$CUSTOM_FILE")
else
  [[ -f "$HOME/.bash_history" ]]                  && HISTORY_FILES+=("$HOME/.bash_history")
  [[ -f "$HOME/.zsh_history" ]]                   && HISTORY_FILES+=("$HOME/.zsh_history")
  [[ -f "$HOME/.local/share/fish/fish_history" ]] && HISTORY_FILES+=("$HOME/.local/share/fish/fish_history")
fi

[[ ${#HISTORY_FILES[@]} -eq 0 ]] && { error "No history files found."; exit 1; }

# ── CSV header ────────────────────────────────────────────────────────────────
[[ -n "$OUTPUT_FILE" ]] && echo "File,Line,Severity,Type,Match,Entropy" > "$OUTPUT_FILE"

# ── Banner ────────────────────────────────────────────────────────────────────
if ! $QUIET; then
  log ""
  log "${BOLD}SecretHunt — Shell History Secret Scanner${RESET}"
  log "Min severity : ${MIN_SEVERITY}"
  log "Files        : ${#HISTORY_FILES[@]} found"
  log "$(printf '─%.0s' {1..60})"
  log ""
fi

# ── Pattern definitions ───────────────────────────────────────────────────────
# Format: "SEVERITY|DISPLAY TYPE|ERE regex"
# All regexes are used with bash [[ $line =~ $regex ]] — pure built-in, no fork
declare -a PATTERNS=(
  # HIGH — well-known token formats
  "high|AWS Access Key ID|AKIA[0-9A-Z]{16}"
  "high|AWS Secret Access Key|(aws_secret|AWS_SECRET)[_a-zA-Z]*[[:space:]]*=[[:space:]]*[A-Za-z0-9/+]{40}"
  "high|GitHub Token|(ghp_|gho_|ghu_|ghs_|ghr_)[A-Za-z0-9]{36,}"
  "high|GitHub Classic Token|github[_-]?token[[:space:]]*=[[:space:]]*[a-f0-9]{40}"
  "high|Stripe Secret Key|sk_(live|test)_[A-Za-z0-9]{24,}"
  "high|Stripe Publishable Key|pk_(live|test)_[A-Za-z0-9]{24,}"
  "high|Twilio Account SID|AC[a-f0-9]{32}"
  "high|Twilio Auth Token|twilio[_-]?auth[_-]?token[[:space:]]*=[[:space:]]*[a-f0-9]{32}"
  "high|SendGrid API Key|SG\.[A-Za-z0-9_-]{22,}\.[A-Za-z0-9_-]{43,}"
  "high|Slack Token|xox[baprs]-[A-Za-z0-9-]{10,}"
  "high|Slack Webhook|hooks\.slack\.com/services/[A-Za-z0-9/]+"
  "high|Google API Key|AIza[0-9A-Za-z_-]{35}"
  "high|Google OAuth Token|ya29\.[0-9A-Za-z_-]+"
  "high|Heroku API Key|heroku[_-]?api[_-]?key[[:space:]]*=[[:space:]]*[a-f0-9-]{36}"
  "high|npm Auth Token|_authToken=[A-Za-z0-9-]+"
  "high|Private Key Header|-----BEGIN[[:space:]]+(RSA[[:space:]]+|EC[[:space:]]+|OPENSSH[[:space:]]+|DSA[[:space:]]+)?PRIVATE KEY-----"
  "high|JWT Token|eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+"
  "high|DB Connection String|(mysql|postgres|mongodb|redis)://[^:]+:[^@]+@"
  "high|Bearer Token|[Aa]uthorization:[[:space:]]*[Bb]earer[[:space:]]+[A-Za-z0-9_.~+/-]+={0,2}"
  "high|Basic Auth in URL|https?://[^[:space:]]+:[^@[:space:]]+@[^[:space:]]+"
  # MEDIUM — generic assignments
  "medium|Generic API Key|(api_key|apikey|api-key)[[:space:]]*=[[:space:]]*['\"]?[A-Za-z0-9_-]{16,}"
  "medium|Generic Secret|(client_secret|app_secret|secret_key)[[:space:]]*=[[:space:]]*['\"]?[A-Za-z0-9_-]{8,}"
  "medium|Generic Token|(auth_token|access_token)[[:space:]]*=[[:space:]]*['\"]?[A-Za-z0-9_-]{16,}"
  "medium|Generic Password|(password|passwd|pwd)[[:space:]]*=[[:space:]]*['\"]?[^'\"[:space:]]{6,}"
  "medium|SSH Identity File|(-i|--identity)[[:space:]]+[^[:space:]]+\.pem"
  "medium|curl with Credentials|curl[[:space:]].*(-u|--user)[[:space:]]+[^:[:space:]]+:[^[:space:]]+"
  # LOW — export / env var assignments
  "low|Exported Credential|export[[:space:]]+(API_KEY|SECRET|TOKEN|PASSWORD|PASSWD|AUTH|CREDENTIAL)[[:space:]]*="
  "low|Env Var Assignment|(API_KEY|SECRET_KEY|AUTH_TOKEN|DB_PASSWORD|PRIVATE_KEY)[[:space:]]*=[[:space:]]*[^[:space:]]+"
  "low|scp/rsync with Key|(scp|rsync)[[:space:]].*-i[[:space:]]+[^[:space:]]+\.(pem|key)"
  "low|sshpass|sshpass[[:space:]]+-p[[:space:]]*[^[:space:]]+"
)

# ── Counters ──────────────────────────────────────────────────────────────────
total_lines=0
total_findings=0
high_count=0
medium_count=0
low_count=0

# ── Main scan loop ────────────────────────────────────────────────────────────
for hist_file in "${HISTORY_FILES[@]}"; do
  $QUIET || log "${BOLD}Scanning:${RESET} ${CYAN}${hist_file}${RESET}"

  file_findings=0
  line_num=0

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    (( line_num++ ))  || true
    (( total_lines++ )) || true

    # Strip fish timestamp prefix (": 1699999999:0;command") — pure bash
    line="${raw_line#: +([0-9]):+([0-9]);}"
    # Fallback for shells without extglob: use parameter expansion
    if [[ "$line" == "$raw_line" && "$raw_line" =~ ^:[[:space:]]*[0-9]+:[0-9]+\; ]]; then
      line="${raw_line#*;}"
    fi

    for pattern_def in "${PATTERNS[@]}"; do
      severity="${pattern_def%%|*}"
      rest="${pattern_def#*|}"
      ptype="${rest%%|*}"
      regex="${rest#*|}"

      # Pure bash severity filter — no subshell
      passes_filter "$severity" || continue

      # Pure bash regex match — no grep fork
      if [[ "$line" =~ $regex ]]; then
        matched="${BASH_REMATCH[0]}"

        # Entropy computed only on actual matches
        ent=$(entropy "$matched")

        (( total_findings++ )) || true
        (( file_findings++ ))  || true
        case "$severity" in
          high)   (( high_count++ ))   || true; sev_label="${RED}HIGH  ${RESET}" ;;
          medium) (( medium_count++ )) || true; sev_label="${ORANGE}MEDIUM${RESET}" ;;
          low)    (( low_count++ ))    || true; sev_label="${YELLOW}LOW   ${RESET}" ;;
        esac

        log "  ${sev_label} ${BOLD}Line ${line_num}${RESET} — ${ptype}"
        $QUIET || log "         ${GRAY}${line:0:120}${RESET}"
        $QUIET || log "         Entropy: ${ent} bits  |  Match: ${BOLD}${matched:0:60}${RESET}"
        log ""

        if [[ -n "$OUTPUT_FILE" ]]; then
          safe_line="${line//\"/\"\"}"
          safe_match="${matched//\"/\"\"}"
          printf '"%s",%d,%s,"%s","%s",%s\n' \
            "$hist_file" "$line_num" "$severity" "$ptype" \
            "${safe_match:0:100}" "$ent" >> "$OUTPUT_FILE"
        fi

        break  # one finding per line
      fi
    done
  done < "$hist_file"

  if [[ $file_findings -eq 0 ]]; then
    $QUIET || log "  ${GREEN}No findings.${RESET}"
    $QUIET || log ""
  fi
done

# ── Summary ───────────────────────────────────────────────────────────────────
log "$(printf '─%.0s' {1..60})"
log "${BOLD}Summary${RESET}"
log "  Lines scanned : ${total_lines}"
log "  Total findings: ${BOLD}${total_findings}${RESET}"
log "  ${RED}High: ${high_count}${RESET}  |  ${ORANGE}Medium: ${medium_count}${RESET}  |  ${YELLOW}Low: ${low_count}${RESET}"
[[ -n "$OUTPUT_FILE" ]] && log "  Report saved to: ${OUTPUT_FILE}"
log ""

[[ $total_findings -eq 0 ]] && exit 0 || exit 1
