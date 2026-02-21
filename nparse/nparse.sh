#!/bin/bash
# parse_nmap.sh - Parse Nmap output files and produce a clean, simple report
# Usage: ./parse_nmap.sh [-v] [-d] <nmap_output_file> [nmap_output_file2 ...]
#   -v  Include the Version column in the output
#   -d  Include the resolved domain name in the host title (if any)

SHOW_VERSION=false
SHOW_DOMAIN=false

while getopts "vd" opt; do
    case $opt in
        v) SHOW_VERSION=true ;;
        d) SHOW_DOMAIN=true ;;
        *) echo "Usage: $0 [-v] [-d] <nmap_output_file> [...]"; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -eq 0 ]]; then
    echo "Usage: $0 [-v] [-d] <nmap_output_file> [nmap_output_file2 ...]"
    exit 1
fi

if [[ "$SHOW_VERSION" == true ]]; then
    COL_HEADER="$(printf "%-12s %-10s %-15s %s" "PORT/PROTO" "STATE" "SERVICE" "VERSION")"
    COL_SEP="$(printf "%-12s %-10s %-15s %s" "------------" "----------" "---------------" "-------")"
else
    COL_HEADER="$(printf "%-12s %-10s %s" "PORT/PROTO" "STATE" "SERVICE")"
    COL_SEP="$(printf "%-12s %-10s %s" "------------" "----------" "---------------")"
fi

FIRST_HOST=true

for FILE in "$@"; do
    if [[ ! -f "$FILE" ]]; then
        echo "File not found: $FILE" >&2
        continue
    fi

    CURRENT_IP=""
    CURRENT_DOMAIN=""
    FIRST_PORT=true

    while IFS= read -r LINE; do
        # Strip carriage return (in case of Windows line endings)
        LINE="${LINE%$'\r'}"

        if [[ "$LINE" =~ ^Nmap\ scan\ report\ for ]]; then
            # Print blank line before every host except the very first
            if [[ "$FIRST_HOST" == false ]]; then
                echo ""
            fi
            if [[ "$LINE" =~ ^Nmap\ scan\ report\ for\ (.+)\ \(([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+)\) ]]; then
                CURRENT_DOMAIN="${BASH_REMATCH[1]}"
                CURRENT_IP="${BASH_REMATCH[2]}"
            elif [[ "$LINE" =~ ([0-9]+\.[0-9]+\.[0-9]+\.[0-9]+) ]]; then
                CURRENT_DOMAIN=""
                CURRENT_IP="${BASH_REMATCH[1]}"
            fi
            FIRST_PORT=true
            FIRST_HOST=false
            continue
        fi

        if [[ "$LINE" =~ ^([0-9]+\/(tcp|udp))[[:space:]]+(open|closed|filtered|open\|filtered|closed\|filtered)[[:space:]]+([a-zA-Z0-9_\-]+)[[:space:]]*(.*) ]]; then
            PORT_PROTO="${BASH_REMATCH[1]}"
            STATE="${BASH_REMATCH[3]}"
            SERVICE="${BASH_REMATCH[4]}"
            VERSION="${BASH_REMATCH[5]}"
            VERSION="${VERSION%"${VERSION##*[![:space:]]}"}"

            if [[ "$FIRST_PORT" == true ]]; then
                if [[ "$SHOW_DOMAIN" == true && -n "$CURRENT_DOMAIN" ]]; then
                    echo "Host: $CURRENT_IP ($CURRENT_DOMAIN)"
                else
                    echo "Host: $CURRENT_IP"
                fi
                echo ""
                echo "$COL_HEADER"
                echo "$COL_SEP"
                FIRST_PORT=false
            fi

            if [[ "$SHOW_VERSION" == true ]]; then
                printf "%-12s %-10s %-15s %s\n" "$PORT_PROTO" "$STATE" "$SERVICE" "$VERSION"
            else
                printf "%-12s %-10s %s\n" "$PORT_PROTO" "$STATE" "$SERVICE"
            fi
        fi

    done < "$FILE"
done
