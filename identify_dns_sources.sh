#!/usr/bin/env bash

set -Eeuo pipefail

# Identifie les listes qui bloquent un ou plusieurs domaines DNS.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_SCRIPT="${SCRIPT_DIR}/update_adguard.sh"
MAX_PARALLEL="${MAX_PARALLEL:-5}"

VERBOSE=0

log() {
    if [[ "$VERBOSE" -ne 0 ]]; then
        echo "$@" >&2
    fi
}

usage() {
    cat >&2 <<'EOF'
Usage:
  ./identify_dns_sources.sh domaine1 [domaine2 ...]
  ./identify_dns_sources.sh -f fichier_de_domaines.txt

Le fichier peut contenir un domaine par ligne. Les lignes vides et les
lignes commencant par # sont ignorees.

Exemples:
  ./identify_dns_sources.sh example.com ads.example.com
  ./identify_dns_sources.sh -f dns_a_verifier.txt
EOF
}

for command in awk curl mktemp sed sort; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: '$command' n'est pas installe." >&2
        exit 1
    fi
done

if [[ ! -r "$CONFIG_SCRIPT" ]]; then
    echo "ERROR: configuration introuvable: $CONFIG_SCRIPT" >&2
    exit 1
fi

if [[ "$#" -eq 0 ]]; then
    usage
    exit 1
fi

DOMAINS_FILE=""
CREATED_DOMAINS_FILE=0
if [[ "$1" == "-f" ]]; then
    if [[ "$#" -ne 2 ]] || [[ ! -r "$2" ]]; then
        echo "ERROR: fichier de domaines introuvable ou illisible." >&2
        usage
        exit 1
    fi
    DOMAINS_FILE="$2"
else
    DOMAINS_FILE="$(mktemp "${SCRIPT_DIR}/identify_domains.XXXXXX" 2>/dev/null || mktemp)"
    CREATED_DOMAINS_FILE=1
    printf '%s\n' "$@" > "$DOMAINS_FILE"
fi

TMPDIR="$(mktemp -d "${SCRIPT_DIR}/identify_tmp.XXXXXX" 2>/dev/null || mktemp -d)"
cleanup() {
    rm -rf "$TMPDIR"
    if [[ "$CREATED_DOMAINS_FILE" -eq 1 ]] && [[ -n "${DOMAINS_FILE:-}" ]]; then
        rm -f "$DOMAINS_FILE"
    fi
}
trap cleanup EXIT

DOMAINS="$TMPDIR/domains.txt"
awk '
{
    sub(/^\xef\xbb\xbf/, "", $0)
    sub(/\r$/, "", $0)
    sub(/[[:space:]]+#.*$/, "", $0)
    gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
    if ($0 != "" && $0 !~ /^#/) print tolower($0)
}
' "$DOMAINS_FILE" | LC_ALL=C sort -u > "$DOMAINS"

if [[ ! -s "$DOMAINS" ]]; then
    echo "ERROR: aucun domaine a analyser." >&2
    exit 1
fi

URLS="$TMPDIR/urls.txt"
sed -n '/^FILTER_URLS=(/,/^)/p' "$CONFIG_SCRIPT" \
    | sed -n 's/^[[:space:]]*"\(https\?:\/\/[^" ]*\)"[[:space:]]*$/\1/p' > "$URLS"

if [[ ! -s "$URLS" ]]; then
    echo "ERROR: aucune URL de source trouvee dans $CONFIG_SCRIPT" >&2
    exit 1
fi

download_source() {
    local index="$1"
    local url="$2"
    curl --fail --silent --show-error --location --retry 2 \
        --connect-timeout 15 --max-time 600 "$url" \
        -o "$TMPDIR/source-${index}.txt"
}

mapfile -t URL_ARRAY < "$URLS"
PIDS=()
for index in "${!URL_ARRAY[@]}"; do
    while (( ${#PIDS[@]} >= MAX_PARALLEL )); do
        for pid in "${PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                wait "$pid" || true
                PIDS=( $(printf '%s\n' "${PIDS[@]}" | awk -v pid="$pid" '$0 != pid') )
                break
            fi
        done
        sleep 0.2
    done
    download_source "$index" "${URL_ARRAY[$index]}" &
    PIDS+=("$!")
done

FAILED=0
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        FAILED=$((FAILED + 1))
    fi
done

if [[ "$FAILED" -ne 0 ]]; then
    echo "ERROR: $FAILED source(s) n'ont pas pu etre telechargee(s)." >&2
    exit 1
fi

RULES="$TMPDIR/rules.txt"
for index in "${!URL_ARRAY[@]}"; do
    awk -v source="$index" '
    function valid(domain) {
        return domain ~ /^(\*\.)?[A-Za-z0-9][A-Za-z0-9._-]*$/ && domain !~ /\.\./
    }
    {
        sub(/^\xef\xbb\xbf/, "", $0)
        sub(/\r$/, "", $0)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", $0)
        if ($0 == "" || $0 ~ /^!/ || $0 ~ /^#/ || $0 ~ /##|#@#|#\+#/) next
        if ($0 ~ /^(0\.0\.0\.0|127\.0\.0\.1|::)[[:space:]]+/) {
            count = split($0, fields, /[[:space:]]+/)
            for (i = 2; i <= count; i++) {
                domain = fields[i]
                sub(/#.*/, "", domain)
                if (valid(domain)) print source "\t" tolower(domain)
            }
            next
        }
        if ($0 ~ /^\|\|/) {
            sub(/^\|\|/, "", $0)
            domain = $0
            sub(/[\^\/$|[:space:]].*$/, "", domain)
            sub(/\.$/, "", domain)
            if (valid(domain)) print source "\t" tolower(domain)
            next
        }
        if ($0 ~ /^(\*\.)?[A-Za-z0-9._-]+$/ && valid($0)) print source "\t" tolower($0)
    }
    ' "$TMPDIR/source-${index}.txt" >> "$RULES"
done

echo "DNS analyse(s):"
while IFS= read -r domain; do
    matches=$(awk -F '\t' -v domain="$domain" '
        function matches_rule(rule) {
            sub(/^\*\./, "", rule)
            return domain == rule || domain ~ ("\\." rule "$")
        }
        matches_rule($2) { print $1 }
    ' "$RULES" | LC_ALL=C sort -nu)

    echo
    echo "$domain"
    if [[ -z "$matches" ]]; then
        echo "  Aucune source ne bloque ce domaine."
    else
        while IFS= read -r source_index; do
            printf '  - %s\n' "${URL_ARRAY[$source_index]}"
        done <<< "$matches"
    fi
done < "$DOMAINS"
