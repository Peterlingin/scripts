#!/usr/bin/bash
# =============================================================================
# dnsprop.sh - Smart DNS Propagation Checker
# =============================================================================
# Poll multiple public resolvers in parallel after a DNS record change,
# display a live in-place dashboard, and alert when consensus is reached.
#
# Part of the sysadmin toolkit series (secrethunt.sh, fim.sh, dnsprop.sh).
#
# Usage: dnsprop.sh [OPTIONS] <domain>
# See --help for full usage.
#
# Dependencies: dig (bind-utils / dnsutils), tput, logger
# License: MIT
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_NAME
readonly VERSION="1.0.0"
readonly SYSLOG_TAG="dnsprop"

# Resolver table entries: "Human-readable name|IP"
RESOLVERS=(
    "Google Primary|8.8.8.8"
    "Google Secondary|8.8.4.4"
    "Cloudflare Primary|1.1.1.1"
    "Cloudflare Secondary|1.0.0.1"
    "OpenDNS Primary|208.67.222.222"
    "OpenDNS Secondary|208.67.220.220"
    "Quad9|9.9.9.9"
)
readonly RESOLVERS

SUPPORTED_TYPES=(A AAAA CNAME MX TXT NS SOA)
readonly SUPPORTED_TYPES

DEFAULT_INTERVAL=30
DEFAULT_MAX_WAIT=3600
DEFAULT_DIG_TIMEOUT=5

# ---------------------------------------------------------------------------
# Colour variables - populated by setup_colours() after terminal check
# ---------------------------------------------------------------------------
C_RESET="" C_BOLD="" C_DIM=""
C_GREEN="" C_RED="" C_YELLOW="" C_CYAN="" C_WHITE=""
C_BG_GREEN="" C_BG_RED="" C_BG_YELLOW=""

setup_colours() {
    if [[ -t 1 ]] \
       && command -v tput &>/dev/null \
       && tput colors &>/dev/null \
       && (( $(tput colors) >= 8 )); then
        C_RESET=$(tput sgr0)
        C_BOLD=$(tput bold)
        C_DIM=$(tput dim 2>/dev/null || printf '')
        C_GREEN=$(tput setaf 2)
        C_RED=$(tput setaf 1)
        C_YELLOW=$(tput setaf 3)
        C_CYAN=$(tput setaf 6)
        C_WHITE=$(tput setaf 7)
        C_BG_GREEN=$(tput setab 2)
        C_BG_RED=$(tput setab 1)
        C_BG_YELLOW=$(tput setab 3)
    fi
}

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()  { printf '%s[INFO]%s  %s\n'  "${C_CYAN}"   "${C_RESET}" "$*"; }
log_warn()  { printf '%s[WARN]%s  %s\n'  "${C_YELLOW}" "${C_RESET}" "$*" >&2; }
log_error() { printf '%s[ERROR]%s %s\n'  "${C_RED}"    "${C_RESET}" "$*" >&2; }

syslog_notice() { logger -t "$SYSLOG_TAG" -p "daemon.notice"  "$*" 2>/dev/null || true; }
syslog_info()   { logger -t "$SYSLOG_TAG" -p "daemon.info"    "$*" 2>/dev/null || true; }
syslog_warn()   { logger -t "$SYSLOG_TAG" -p "daemon.warning" "$*" 2>/dev/null || true; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
${C_BOLD}${C_CYAN}dnsprop.sh${C_RESET} v${VERSION} - Smart DNS Propagation Checker

${C_BOLD}USAGE${C_RESET}
    $SCRIPT_NAME [OPTIONS] <domain>

${C_BOLD}OPTIONS${C_RESET}
    -t, --type <TYPE>         Record type to check. Repeatable.
                              Supported: A AAAA CNAME MX TXT NS SOA
                              Default: A

    -e, --expected <VALUE>    Expected value for 'expected' consensus mode.
                              Repeatable for multi-value records (e.g. MX).

    -m, --mode <MODE>         Consensus mode:
                                strict    All resolvers must agree (default)
                                threshold N% of resolvers must agree
                                expected  All resolvers must return --expected value(s)

        --threshold <PCT>     Percentage (1-100) for threshold mode. Default: 80

    -i, --interval <SEC>      Poll interval in seconds. Default: ${DEFAULT_INTERVAL}
    -w, --max-wait <SEC>      Maximum wait before giving up. Default: ${DEFAULT_MAX_WAIT}
        --dig-timeout <SEC>   Per-query dig timeout. Default: ${DEFAULT_DIG_TIMEOUT}

    -o, --output <FILE>       Write CSV report to FILE.
        --no-bell             Suppress terminal bell on consensus.
        --list-resolvers      Print resolver set and exit.

    -h, --help                Show this help and exit.
        --version             Show version and exit.

${C_BOLD}EXAMPLES${C_RESET}
    # A record, strict consensus, poll every 60 s, give up after 2 h
    $SCRIPT_NAME --type A --interval 60 --max-wait 7200 example.com

    # A + MX, expected-value mode, CSV report
    $SCRIPT_NAME --type A --type MX --mode expected \\
        --expected 203.0.113.42 --expected "10 mail.example.com." \\
        --output /tmp/dns.csv example.com

    # TXT, 80% threshold, 30 s interval
    $SCRIPT_NAME --type TXT --mode threshold --threshold 80 \\
        --interval 30 --max-wait 1800 example.com

    # List configured resolvers
    $SCRIPT_NAME --list-resolvers

${C_BOLD}CONSENSUS MODES${C_RESET}
    strict    All non-timeout resolvers return identical answer sets.
    threshold The most common answer appears in >= N% of non-timeout responses.
    expected  All non-timeout resolvers return every --expected value.

${C_BOLD}CSV COLUMNS${C_RESET}
    resolver_name, resolver_ip, record_type, returned_value,
    ttl, latency_ms, consensus_status

${C_BOLD}EXIT CODES${C_RESET}
    0  Consensus reached
    1  Max-wait exceeded without consensus
    2  Usage / configuration error
    3  Missing dependency (dig)
EOF
}

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
check_deps() {
    if ! command -v dig &>/dev/null; then
        log_error "dig not found. Install bind-utils (RHEL/CentOS) or dnsutils (Debian/Ubuntu)."
        exit 3
    fi
    if ! command -v tput &>/dev/null; then
        log_warn "tput not found - colour and in-place redraw disabled."
    fi
}

# ---------------------------------------------------------------------------
# Argument parsing
# Globals set: DOMAIN, TYPES, EXPECTED_VALUES, CONSENSUS_MODE, THRESHOLD,
#              INTERVAL, MAX_WAIT, DIG_TIMEOUT, CSV_FILE, NO_BELL
# ---------------------------------------------------------------------------
DOMAIN=""
TYPES=()
EXPECTED_VALUES=()
CONSENSUS_MODE="strict"
THRESHOLD=80
INTERVAL=$DEFAULT_INTERVAL
MAX_WAIT=$DEFAULT_MAX_WAIT
DIG_TIMEOUT=$DEFAULT_DIG_TIMEOUT
CSV_FILE=""
NO_BELL=0

parse_args() {
    local args
    args=$(getopt \
        -o ht:e:m:i:w:o: \
        --long help,version,type:,expected:,mode:,threshold:,interval:,max-wait:,dig-timeout:,output:,no-bell,list-resolvers \
        -n "$SCRIPT_NAME" -- "$@") || { usage; exit 2; }
    eval set -- "$args"

    local list_resolvers=0

    while true; do
        case "$1" in
            -h|--help)           usage; exit 0 ;;
            --version)           printf '%s v%s\n' "$SCRIPT_NAME" "$VERSION"; exit 0 ;;
            --list-resolvers)    list_resolvers=1; shift ;;
            -t|--type)           TYPES+=("${2^^}"); shift 2 ;;
            -e|--expected)       EXPECTED_VALUES+=("$2"); shift 2 ;;
            -m|--mode)           CONSENSUS_MODE="$2"; shift 2 ;;
            --threshold)         THRESHOLD="$2"; shift 2 ;;
            -i|--interval)       INTERVAL="$2"; shift 2 ;;
            -w|--max-wait)       MAX_WAIT="$2"; shift 2 ;;
            --dig-timeout)       DIG_TIMEOUT="$2"; shift 2 ;;
            -o|--output)         CSV_FILE="$2"; shift 2 ;;
            --no-bell)           NO_BELL=1; shift ;;
            --)                  shift; break ;;
            *)                   log_error "Unknown option: $1"; usage; exit 2 ;;
        esac
    done

    [[ ${#TYPES[@]} -eq 0 ]] && TYPES=("A")

    if (( list_resolvers )); then
        print_resolvers
        exit 0
    fi

    [[ $# -lt 1 ]] && { log_error "Domain argument required."; usage; exit 2; }
    DOMAIN="$1"

    # Validate record types
    local t s valid
    for t in "${TYPES[@]}"; do
        valid=0
        for s in "${SUPPORTED_TYPES[@]}"; do
            [[ "$t" == "$s" ]] && valid=1 && break
        done
        (( valid )) || { log_error "Unsupported record type: $t"; exit 2; }
    done

    # Validate consensus mode
    case "$CONSENSUS_MODE" in
        strict|threshold|expected) ;;
        *) log_error "Invalid mode: $CONSENSUS_MODE. Use strict, threshold, or expected."; exit 2 ;;
    esac

    if [[ "$CONSENSUS_MODE" == "expected" && ${#EXPECTED_VALUES[@]} -eq 0 ]]; then
        log_error "Mode 'expected' requires at least one --expected value."
        exit 2
    fi

    # Validate numeric args
    local v
    for v in "$INTERVAL" "$MAX_WAIT" "$DIG_TIMEOUT" "$THRESHOLD"; do
        [[ "$v" =~ ^[0-9]+$ ]] || { log_error "Numeric arguments must be positive integers."; exit 2; }
    done
    (( THRESHOLD >= 1 && THRESHOLD <= 100 )) \
        || { log_error "--threshold must be between 1 and 100."; exit 2; }
    (( INTERVAL >= 1 )) \
        || { log_error "--interval must be >= 1."; exit 2; }
    (( MAX_WAIT >= INTERVAL )) \
        || { log_error "--max-wait must be >= --interval."; exit 2; }
}

# ---------------------------------------------------------------------------
# Resolver listing
# ---------------------------------------------------------------------------
print_resolvers() {
    printf '%s%-24s %s%s\n' "${C_BOLD}${C_CYAN}" "RESOLVER" "IP" "${C_RESET}"
    printf '%0.s-' {1..40}; printf '\n'
    local entry name ip
    for entry in "${RESOLVERS[@]}"; do
        name="${entry%%|*}"
        ip="${entry##*|}"
        printf '%-24s %s\n' "$name" "$ip"
    done
}

# ---------------------------------------------------------------------------
# CSV helpers
# ---------------------------------------------------------------------------
csv_init() {
    [[ -z "$CSV_FILE" ]] && return
    printf 'resolver_name,resolver_ip,record_type,returned_value,ttl,latency_ms,consensus_status\n' \
        > "$CSV_FILE" || { log_error "Cannot write CSV: $CSV_FILE"; exit 2; }
}

# csv_append NAME IP TYPE VALUE TTL LATENCY CONSENSUS
csv_append() {
    [[ -z "$CSV_FILE" ]] && return
    printf '%s,%s,%s,"%s",%s,%s,%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$6" "$7" >> "$CSV_FILE"
}

# ---------------------------------------------------------------------------
# Core: query one resolver for one record type
# Appends tab-separated rows to $4:
#   NAME <TAB> IP <TAB> TYPE <TAB> VALUE <TAB> TTL <TAB> LATENCY_MS
# Multiple RRs produce multiple rows.
# ---------------------------------------------------------------------------
query_resolver() {
    local name="$1" ip="$2" type="$3" outfile="$4"

    local t_start t_end latency_ms
    t_start=$(date +%s%3N)

    local raw
    raw=$(dig +noall +answer \
             +time="${DIG_TIMEOUT}" +tries=1 \
             "@${ip}" "${DOMAIN}" "${type}" 2>/dev/null) || true

    t_end=$(date +%s%3N)
    latency_ms=$(( t_end - t_start ))

    if [[ -z "$raw" ]]; then
        printf '%s\t%s\t%s\tTIMEOUT\t-\t%s\n' \
            "$name" "$ip" "$type" "$latency_ms" >> "$outfile"
        return
    fi

    local found=0 line ttl value
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        # dig +answer format: owner TTL class type rdata...
        ttl=$(awk '{print $2}' <<< "$line")
        value=$(awk '{for(i=5;i<=NF;i++) printf "%s%s",$i,(i<NF?" ":""); print ""}' <<< "$line")
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$name" "$ip" "$type" "$value" "$ttl" "$latency_ms" >> "$outfile"
        found=1
    done <<< "$raw"

    if (( ! found )); then
        printf '%s\t%s\t%s\tNXDOMAIN\t-\t%s\n' \
            "$name" "$ip" "$type" "$latency_ms" >> "$outfile"
    fi
}

# ---------------------------------------------------------------------------
# Poll all resolvers x all types in parallel; return path to temp result file
# ---------------------------------------------------------------------------
poll_all() {
    local tmpfile
    tmpfile=$(mktemp /tmp/dnsprop_results.XXXXXX)

    local pids=() entry name ip type
    for entry in "${RESOLVERS[@]}"; do
        name="${entry%%|*}"
        ip="${entry##*|}"
        for type in "${TYPES[@]}"; do
            query_resolver "$name" "$ip" "$type" "$tmpfile" &
            pids+=($!)
        done
    done

    local pid
    for pid in "${pids[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    printf '%s' "$tmpfile"
}

# ---------------------------------------------------------------------------
# Consensus evaluation
# Reads: CONSENSUS_MODE, THRESHOLD, EXPECTED_VALUES, TYPES
# Sets:  CONSENSUS_REACHED (0/1), CONSENSUS_VALUE (string)
# ---------------------------------------------------------------------------
CONSENSUS_REACHED=0
CONSENSUS_VALUE=""

evaluate_consensus() {
    local tmpfile="$1"

    CONSENSUS_REACHED=0
    CONSENSUS_VALUE=""

    local type
    for type in "${TYPES[@]}"; do
        # Collect non-error values for this type
        local values=()
        local rname rip rtype rvalue rttl rlatency
        while IFS=$'\t' read -r rname rip rtype rvalue rttl rlatency; do
            [[ "$rtype" == "$type" ]] || continue
            [[ "$rvalue" == "TIMEOUT" || "$rvalue" == "NXDOMAIN" ]] && continue
            values+=("$rvalue")
        done < "$tmpfile"

        local total=${#values[@]}
        (( total == 0 )) && { CONSENSUS_REACHED=0; return; }

        case "$CONSENSUS_MODE" in

            strict)
                local first="${values[0]}" v all_same=1
                for v in "${values[@]}"; do
                    [[ "$v" != "$first" ]] && { all_same=0; break; }
                done
                if (( all_same )); then
                    CONSENSUS_REACHED=1
                    CONSENSUS_VALUE="$first"
                else
                    CONSENSUS_REACHED=0
                    return
                fi
                ;;

            threshold)
                # Count occurrences without associative arrays (bash 3 compat)
                local best_val="" best_count=0 count v v2
                for v in "${values[@]}"; do
                    count=0
                    for v2 in "${values[@]}"; do
                        [[ "$v2" == "$v" ]] && (( count++ )) || true
                    done
                    if (( count > best_count )); then
                        best_count=$count
                        best_val="$v"
                    fi
                done
                local pct=$(( best_count * 100 / total ))
                if (( pct >= THRESHOLD )); then
                    CONSENSUS_REACHED=1
                    CONSENSUS_VALUE="${best_val} (${pct}% of ${total} resolvers)"
                else
                    CONSENSUS_REACHED=0
                    return
                fi
                ;;

            expected)
                local exp found v match=1
                for exp in "${EXPECTED_VALUES[@]}"; do
                    found=0
                    for v in "${values[@]}"; do
                        [[ "$v" == *"$exp"* ]] && { found=1; break; }
                    done
                    (( found )) || { match=0; break; }
                done
                if (( match )); then
                    CONSENSUS_REACHED=1
                    CONSENSUS_VALUE="${EXPECTED_VALUES[*]}"
                else
                    CONSENSUS_REACHED=0
                    return
                fi
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Terminal geometry
# ---------------------------------------------------------------------------
TERM_COLS=80
TERM_ROWS=24

update_term_size() {
    TERM_COLS=$(tput cols  2>/dev/null || printf '80')
    TERM_ROWS=$(tput lines 2>/dev/null || printf '24')
}

# ---------------------------------------------------------------------------
# Dashboard primitives
# ---------------------------------------------------------------------------

# hr [CHAR] - full-width horizontal rule
hr() {
    printf '%s' "${C_DIM}"
    printf '%*s' "$TERM_COLS" '' | tr ' ' "${1:--}"
    printf '%s\n' "${C_RESET}"
}

# field STR WIDTH - left-align / truncate to exact character width
field() { printf '%-*.*s' "$2" "$2" "$1"; }

# badge STATUS - fixed-width colour pill (11 visible chars + colour escapes)
badge() {
    case "$1" in
        OK)       printf '%s [OK]      %s' "${C_BOLD}${C_BG_GREEN}${C_WHITE}"   "${C_RESET}" ;;
        TIMEOUT)  printf '%s [!!] TIMEOUT  %s' "${C_BOLD}${C_BG_RED}${C_WHITE}"    "${C_RESET}" ;;
        NXDOMAIN) printf '%s [!!] NXDOMAIN %s' "${C_BOLD}${C_BG_RED}${C_WHITE}"    "${C_RESET}" ;;
        MISMATCH) printf '%s [!=] MISMATCH %s' "${C_BOLD}${C_BG_YELLOW}${C_WHITE}" "${C_RESET}" ;;
        PENDING)  printf '%s [..] PENDING  %s' "${C_DIM}"                           "${C_RESET}" ;;
        *)        printf '%s ? %-8s  %s'    "${C_DIM}" "$1"                      "${C_RESET}" ;;
    esac
}

format_duration() {
    printf '%02d:%02d:%02d' \
        $(( $1 / 3600 )) \
        $(( ($1 % 3600) / 60 )) \
        $(( $1 % 60 ))
}

# ---------------------------------------------------------------------------
# Full dashboard redraw
# Globals read: ROUND, ELAPSED, NEXT_POLL_IN, CONSENSUS_REACHED, CONSENSUS_VALUE
# ---------------------------------------------------------------------------

# Fixed row index of the Round/Elapsed/Next-poll line (0-based tput cup row)
# header=0, rule=1, domain=2, types=3, mode=4, round=5
readonly ROUND_ROW=5

draw_dashboard() {
    local tmpfile="$1"
    update_term_size

    tput cup 0 0
    tput ed

    # -- Header ----------------------------------------------------------------
    printf '%s> DNS Propagation Checker%s  v%s\n' \
        "${C_BOLD}${C_CYAN}" "${C_RESET}" "$VERSION"
    hr "="
    printf '  %sDomain:%s  %s%s%s\n' \
        "${C_BOLD}" "${C_RESET}" "${C_BOLD}${C_CYAN}" "$DOMAIN" "${C_RESET}"
    printf '  %sTypes:%s   %s\n' "${C_BOLD}" "${C_RESET}" "${TYPES[*]}"
    printf '  %sMode:%s    %s' "${C_BOLD}" "${C_RESET}" "$CONSENSUS_MODE"
    [[ "$CONSENSUS_MODE" == "threshold" ]] && printf ' (%s%%)' "$THRESHOLD"
    [[ "$CONSENSUS_MODE" == "expected" ]]  && printf ' -> %s' "${EXPECTED_VALUES[*]}"
    printf '\n'
    printf '  %sRound:%s %s  %sElapsed:%s %s  %sNext poll:%s %ss  \n' \
        "${C_BOLD}" "${C_RESET}" "$ROUND" \
        "${C_BOLD}" "${C_RESET}" "$(format_duration "$ELAPSED")" \
        "${C_BOLD}" "${C_RESET}" "$NEXT_POLL_IN"
    hr

    # -- Column headers ---------------------------------------------------------
    printf '%s%-24s %-16s %-6s %-12s %-7s %-7s %s%s\n' \
        "${C_BOLD}" \
        "RESOLVER" "IP" "TYPE" "STATUS" "TTL" "MS" "VALUE" \
        "${C_RESET}"
    hr

    # -- Build parallel arrays from tmpfile (no subshells, no assoc arrays) -----
    # Pre-fill with PENDING for every resolver x type slot
    local -a row_names=() row_ips=() row_types=()
    local -a row_values=() row_ttls=() row_latencies=()
    local entry name ip type
    for entry in "${RESOLVERS[@]}"; do
        name="${entry%%|*}"
        ip="${entry##*|}"
        for type in "${TYPES[@]}"; do
            row_names+=("$name")
            row_ips+=("$ip")
            row_types+=("$type")
            row_values+=("PENDING")
            row_ttls+=("-")
            row_latencies+=("-")
        done
    done

    local total_slots=${#row_names[@]}
    local rname rip rtype rvalue rttl rlatency n
    while IFS=$'\t' read -r rname rip rtype rvalue rttl rlatency; do
        for (( n=0; n<total_slots; n++ )); do
            if [[ "${row_names[$n]}"  == "$rname" \
               && "${row_ips[$n]}"    == "$rip"   \
               && "${row_types[$n]}"  == "$rtype"  ]]; then
                if [[ "${row_values[$n]}" == "PENDING" ]]; then
                    row_values[$n]="$rvalue"
                    row_ttls[$n]="$rttl"
                    row_latencies[$n]="$rlatency"
                else
                    # Append additional RRs (e.g. MX, multi-TXT)
                    row_values[$n]="${row_values[$n]} / $rvalue"
                fi
                break
            fi
        done
    done < "$tmpfile"

    # -- Render rows ------------------------------------------------------------
    local val_col_width status value trunc_value exp base_cv
    val_col_width=$(( TERM_COLS - 24 - 16 - 6 - 12 - 7 - 7 - 4 ))
    (( val_col_width < 10 )) && val_col_width=10

    for (( n=0; n<total_slots; n++ )); do
        value="${row_values[$n]}"

        case "$value" in
            TIMEOUT)  status="TIMEOUT"  ;;
            NXDOMAIN) status="NXDOMAIN" ;;
            PENDING)  status="PENDING"  ;;
            *)
                case "$CONSENSUS_MODE" in
                    expected)
                        local match=1
                        for exp in "${EXPECTED_VALUES[@]}"; do
                            [[ "$value" == *"$exp"* ]] || { match=0; break; }
                        done
                        (( match )) && status="OK" || status="MISMATCH"
                        ;;
                    *)
                        if (( CONSENSUS_REACHED )) && [[ -n "$CONSENSUS_VALUE" ]]; then
                            base_cv="${CONSENSUS_VALUE%% (*}"
                            [[ "$value" == "$base_cv" ]] && status="OK" || status="MISMATCH"
                        else
                            status="OK"
                        fi
                        ;;
                esac
                ;;
        esac

        trunc_value="${value:0:$val_col_width}"
        [[ "${#value}" -gt "$val_col_width" ]] && trunc_value="${trunc_value}..."

        printf '%-24s %-16s %-6s ' \
            "$(field "${row_names[$n]}" 24)" \
            "$(field "${row_ips[$n]}"   16)" \
            "$(field "${row_types[$n]}"  6)"
        badge "$status"
        printf ' %-7s %-7s %s\n' \
            "$(field "${row_ttls[$n]}"      7)" \
            "$(field "${row_latencies[$n]}" 7)" \
            "$trunc_value"
    done

    hr

    # -- Consensus footer -------------------------------------------------------
    if (( CONSENSUS_REACHED )); then
        printf '%s[OK] CONSENSUS REACHED%s  %s\n' \
            "${C_BOLD}${C_GREEN}" "${C_RESET}" "$CONSENSUS_VALUE"
    else
        printf '%s[..] Waiting for consensus...%s\n' "${C_YELLOW}" "${C_RESET}"
    fi

    [[ -n "$CSV_FILE" ]] && \
        printf '  %sCSV -> %s%s\n' "${C_DIM}" "$CSV_FILE" "${C_RESET}"

    hr "-"
    printf '  %sPress Ctrl-C to abort%s\n' "${C_DIM}" "${C_RESET}"
}

# ---------------------------------------------------------------------------
# Live countdown - updates only the Round/Elapsed/Next-poll line
# ---------------------------------------------------------------------------
live_countdown() {
    local secs="$1" i
    for (( i = secs; i >= 1; i-- )); do
        NEXT_POLL_IN=$i
        tput cup $ROUND_ROW 0
        printf '  %sRound:%s %s  %sElapsed:%s %s  %sNext poll:%s %ss   \n' \
            "${C_BOLD}" "${C_RESET}" "$ROUND" \
            "${C_BOLD}" "${C_RESET}" "$(format_duration "$ELAPSED")" \
            "${C_BOLD}" "${C_RESET}" "$NEXT_POLL_IN"
        sleep 1
        (( ELAPSED++ )) || true   # guard against set -e on arithmetic 0
    done
    NEXT_POLL_IN=0
}

# ---------------------------------------------------------------------------
# Flush results to CSV (parallel-array aggregation, no subshells)
# ---------------------------------------------------------------------------
flush_csv() {
    local tmpfile="$1"
    [[ -z "$CSV_FILE" ]] && return

    local consensus_label
    (( CONSENSUS_REACHED )) && consensus_label="YES" || consensus_label="NO"

    local -a knames=() kips=() ktypes=() kvalues=() kttls=() klatencies=()
    local rname rip rtype rvalue rttl rlatency found_idx k

    while IFS=$'\t' read -r rname rip rtype rvalue rttl rlatency; do
        found_idx=-1
        for (( k=0; k<${#knames[@]}; k++ )); do
            if [[ "${knames[$k]}" == "$rname" \
               && "${kips[$k]}"   == "$rip"   \
               && "${ktypes[$k]}" == "$rtype"  ]]; then
                found_idx=$k
                break
            fi
        done
        if (( found_idx >= 0 )); then
            kvalues[$found_idx]="${kvalues[$found_idx]} / $rvalue"
        else
            knames+=("$rname")
            kips+=("$rip")
            ktypes+=("$rtype")
            kvalues+=("$rvalue")
            kttls+=("$rttl")
            klatencies+=("$rlatency")
        fi
    done < "$tmpfile"

    for (( k=0; k<${#knames[@]}; k++ )); do
        csv_append \
            "${knames[$k]}" "${kips[$k]}" "${ktypes[$k]}" \
            "${kvalues[$k]}" "${kttls[$k]}" "${klatencies[$k]}" \
            "$consensus_label"
    done
}

# ---------------------------------------------------------------------------
# Cleanup on exit / signal
# ---------------------------------------------------------------------------
TMPFILE_GLOBAL=""

cleanup() {
    [[ -n "$TMPFILE_GLOBAL" && -f "$TMPFILE_GLOBAL" ]] && rm -f "$TMPFILE_GLOBAL"
    tput cnorm 2>/dev/null || true
    printf '\n'
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    setup_colours
    check_deps
    parse_args "$@"
    csv_init

    syslog_info "dnsprop started: domain=${DOMAIN} types=${TYPES[*]} mode=${CONSENSUS_MODE} interval=${INTERVAL}s max-wait=${MAX_WAIT}s"

    tput civis 2>/dev/null || true   # hide cursor for clean dashboard
    clear

    # Main-loop state
    ROUND=0
    ELAPSED=0
    NEXT_POLL_IN=0
    local start_epoch now tmpfile remaining sleep_for
    start_epoch=$(date +%s)

    while true; do
        (( ROUND++ )) || true

        # Poll ---------------------------------------------------------------
        tmpfile=$(poll_all)
        TMPFILE_GLOBAL="$tmpfile"

        # Evaluate -----------------------------------------------------------
        evaluate_consensus "$tmpfile"

        # CSV ----------------------------------------------------------------
        flush_csv "$tmpfile"

        # Draw ---------------------------------------------------------------
        now=$(date +%s)
        ELAPSED=$(( now - start_epoch ))
        draw_dashboard "$tmpfile"

        rm -f "$tmpfile"
        TMPFILE_GLOBAL=""

        # Consensus? ---------------------------------------------------------
        if (( CONSENSUS_REACHED )); then
            syslog_notice "Consensus reached: domain=${DOMAIN} types=${TYPES[*]} value=${CONSENSUS_VALUE}"
            printf '\n%s[OK] Consensus reached - exiting.%s\n' \
                "${C_BOLD}${C_GREEN}" "${C_RESET}"
            (( NO_BELL )) || printf '\a'
            exit 0
        fi

        # Max-wait check -----------------------------------------------------
        if (( ELAPSED >= MAX_WAIT )); then
            syslog_warn "Max-wait exceeded without consensus: domain=${DOMAIN}"
            printf '\n%s[!!] Max-wait (%ss) exceeded without consensus.%s\n' \
                "${C_BOLD}${C_RED}" "$MAX_WAIT" "${C_RESET}"
            exit 1
        fi

        # Countdown to next poll ---------------------------------------------
        remaining=$(( MAX_WAIT - ELAPSED ))
        sleep_for=$(( INTERVAL < remaining ? INTERVAL : remaining ))
        live_countdown "$sleep_for"

        now=$(date +%s)
        ELAPSED=$(( now - start_epoch ))
    done
}

main "$@"
