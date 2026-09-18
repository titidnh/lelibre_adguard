#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# AdGuard Home + Blocky - DNS Filter Aggregator
# ============================================================
#
# Objectif :
#   - Télécharger toutes les listes configurées
#   - Convertir en regles DNS AdGuard
#   - Dedupliquer
#   - Generer combined-filter.txt (AdGuard)
#   - Generer blocky-filter.txt (Blocky hosts format)
#   - Commit + push des deux fichiers
#
# ============================================================


# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

OUTPUT_ADGUARD="${SCRIPT_DIR}/combined-filter.txt"
OUTPUT_BLOCKY="${SCRIPT_DIR}/blocky-filter.txt"

MAX_PARALLEL=5
BLOCK_IP="${BLOCK_IP:-0.0.0.0}"

GIT_REPO_DIR="$SCRIPT_DIR"
GIT_FILE_ADGUARD="combined-filter.txt"
GIT_FILE_BLOCKY="blocky-filter.txt"


# ============================================================
# LISTES A AGREGER
# ============================================================

FILTER_URLS=(
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_67.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_39.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_46.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_47.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_66.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_65.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_60.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_55.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_71.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_56.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt"
    "https://easylist-downloads.adblockplus.org/liste_fr.txt"
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/tif.txt"
    "https://cdn.jsdelivr.net/gh/hagezi/dns-blocklists@latest/wildcard/pro.txt"
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt"
    "https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/fake.txt"
    "https://phishing.army/download/phishing_army_blocklist_extended.txt"
)


# ============================================================
# CHECK DEPENDANCES
# ============================================================

for command in curl awk sort mktemp find wc git cmp date head mv rm; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: '$command' n est pas installe." >&2
        exit 1
    fi
done


# ============================================================
# CHECK DOSSIER / GIT
# ============================================================

if [[ ! -d "$SCRIPT_DIR" ]]; then
    echo "ERROR: dossier du script introuvable." >&2
    exit 1
fi

if [[ ! -w "$SCRIPT_DIR" ]]; then
    echo "ERROR: dossier non accessible en ecriture:" >&2
    echo "$SCRIPT_DIR" >&2
    exit 1
fi

if [[ ! -d "${GIT_REPO_DIR}/.git" ]]; then
    echo "ERROR: le dossier du script n est pas un repository Git:" >&2
    echo "$GIT_REPO_DIR" >&2
    exit 1
fi

cd "$GIT_REPO_DIR"

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ERROR: aucun remote Git origin configure." >&2
    exit 1
fi

GIT_BRANCH="$(git branch --show-current)"
if [[ -z "$GIT_BRANCH" ]]; then
    echo "ERROR: impossible de determiner la branche Git courante." >&2
    exit 1
fi

GIT_REMOTE="$(git remote get-url origin)"


# ============================================================
# TEMP DIRECTORY
# ============================================================

TMPDIR="$(mktemp -d "${SCRIPT_DIR}/.adguard-filter-tmp-XXXXXX")"

cleanup() {
    rm -rf "$TMPDIR"
}

trap cleanup EXIT


# ============================================================
# HEADER
# ============================================================

GENERATION_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

echo
echo "============================================================"
echo " AdGuard + Blocky DNS Filter Aggregator"
echo "============================================================"
echo
echo "Generation date    : $GENERATION_DATE"
echo "Script             : $SCRIPT_DIR"
echo "AdGuard output     : $OUTPUT_ADGUARD"
echo "Blocky output      : $OUTPUT_BLOCKY"
echo "Source lists       : ${#FILTER_URLS[@]}"
echo
echo "Git repository     : $GIT_REPO_DIR"
echo "Git branch         : $GIT_BRANCH"
echo "Git remote         : $GIT_REMOTE"
echo
echo "============================================================"
echo


# ============================================================
# DOWNLOAD
# ============================================================

download_filter() {
    local index="$1"
    local url="$2"
    local output="$TMPDIR/filter-${index}.txt"

    echo "[${index}/${#FILTER_URLS[@]}] Downloading..."
    echo "    $url"

    if curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --retry-delay 2 \
        --connect-timeout 15 \
        --max-time 600 \
        "$url" \
        -o "$output"
    then
        echo "    OK"
        return 0
    else
        echo "    FAILED" >&2
        rm -f "$output"
        return 1
    fi
}

PIDS=()
FAILED=0

for i in "${!FILTER_URLS[@]}"; do
    while (( ${#PIDS[@]} >= MAX_PARALLEL )); do
        for pid in "${PIDS[@]}"; do
            if ! kill -0 "$pid" 2>/dev/null; then
                if ! wait "$pid"; then
                    FAILED=$((FAILED + 1))
                fi

                NEW_PIDS=()
                for p in "${PIDS[@]}"; do
                    if [[ "$p" != "$pid" ]]; then
                        NEW_PIDS+=("$p")
                    fi
                done
                PIDS=("${NEW_PIDS[@]}")
                break
            fi
        done
        sleep 0.2
    done

    download_filter "$((i + 1))" "${FILTER_URLS[$i]}" &
    PIDS+=("$!")
done

for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        FAILED=$((FAILED + 1))
    fi
done

echo
echo "============================================================"
echo " Download results"
echo "============================================================"

DOWNLOADED=$(find "$TMPDIR" -type f -name 'filter-*.txt' | wc -l)

echo "Configured lists   : ${#FILTER_URLS[@]}"
echo "Downloaded lists   : $DOWNLOADED"
echo "Failed lists       : $FAILED"
echo

if [[ "$FAILED" -ne 0 ]]; then
    echo "ERROR: telechargement incomplet." >&2
    echo "Les fichiers existants sont conserves." >&2
    exit 1
fi

if [[ "$DOWNLOADED" -ne "${#FILTER_URLS[@]}" ]]; then
    echo "ERROR: nombre de fichiers telecharges incorrect." >&2
    echo "Les fichiers existants sont conserves." >&2
    exit 1
fi


# ============================================================
# NORMALISATION ADGUARD
# ============================================================

NORMALIZED="$TMPDIR/normalized.txt"

awk '

function valid_domain(domain) {
    if (domain !~ /^(\*\.)?[A-Za-z0-9]/) return 0
    if (domain !~ /^\*?[A-Za-z0-9._-]+$/) return 0
    if (domain ~ /^\./ || domain ~ /\.$/) return 0
    if (domain ~ /\.\./) return 0
    if (domain == "localhost" || domain == "localhost.localdomain" || domain == "local") return 0
    if (domain ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return 0
    return 1
}

{
    sub(/^\xef\xbb\xbf/, "", $0)
    sub(/\r$/, "", $0)
    gsub(/^[[:space:]]+/, "", $0)
    gsub(/[[:space:]]+$/, "", $0)

    if ($0 == "") next

    if ($0 ~ /^!/) next
    if ($0 ~ /^#/) next
    if ($0 ~ /^\[/) next

    if ($0 ~ /##/) next
    if ($0 ~ /#@#/) next
    if ($0 ~ /#\+#/) next

    if ($0 ~ /^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]+/) {
        count = split($0, parts, /[[:space:]]+/)
        for (i = 2; i <= count; i++) {
            domain = parts[i]
            sub(/#.*/, "", domain)
            if (domain == "") continue
            if (valid_domain(domain)) print "||" tolower(domain) "^"
        }
        next
    }

    if ($0 ~ /^::[[:space:]]+/) {
        count = split($0, parts, /[[:space:]]+/)
        for (i = 2; i <= count; i++) {
            domain = parts[i]
            if (valid_domain(domain)) print "||" tolower(domain) "^"
        }
        next
    }

    if ($0 ~ /^(@@)?\|\|/) {
        exception = 0
        if ($0 ~ /^@@\|\|/) {
            exception = 1
            sub(/^@@\|\|/, "", $0)
        } else {
            sub(/^\|\|/, "", $0)
        }

        domain = $0
        sub(/[\^\/$|[:space:]].*$/, "", domain)
        sub(/\.$/, "", domain)

        if (valid_domain(domain)) {
            domain = tolower(domain)
            if (exception) print "@@||" domain "^"
            else print "||" domain "^"
        }
        next
    }

    if ($0 ~ /^(\*\.)?[A-Za-z0-9._-]+$/) {
        domain = $0
        if (valid_domain(domain)) print "||" tolower(domain) "^"
        next
    }

    next
}

' "$TMPDIR"/filter-*.txt > "$NORMALIZED"

if [[ ! -s "$NORMALIZED" ]]; then
    echo "ERROR: aucune regle DNS apres normalisation." >&2
    exit 1
fi

SORTED_SIMPLE="$TMPDIR/sorted-simple.txt"
LC_ALL=C sort -u "$NORMALIZED" > "$SORTED_SIMPLE"

if [[ ! -s "$SORTED_SIMPLE" ]]; then
    echo "ERROR: aucune regle apres deduplication." >&2
    exit 1
fi

# Intelligent deduplication: remove rules covered by wildcards
# Example: ||*.tracker.com^ makes ||sub.tracker.com^ redundant
WILDCARDS_FILE="$TMPDIR/wildcards.txt"
EXACT_FILE="$TMPDIR/exact.txt"
SORTED="$TMPDIR/sorted.txt"

# Extract wildcard rules
grep '^\|\|\*\.' "$SORTED_SIMPLE" > "$WILDCARDS_FILE" || true

# Extract exact rules
grep -v '^\|\|\*\.' "$SORTED_SIMPLE" > "$EXACT_FILE" || true

# Filter exact rules: keep only those NOT covered by any wildcard
awk '
BEGIN {
    # Load wildcards file
    wildcards_file = "'"$WILDCARDS_FILE"'"
    while ((getline < wildcards_file) > 0) {
        # Extract domain from ||*.tracker.com^
        domain = $0
        sub(/^\|\|\*\./, "", domain)
        sub(/\^$/, "", domain)
        wildcard[++count] = domain
    }
    close(wildcards_file)
}

{
    # For each exact rule, check if its covered by a wildcard
    domain = $0
    sub(/^\|\|/, "", domain)
    sub(/\^$/, "", domain)
    
    is_covered = 0
    for (i = 1; i <= count; i++) {
        # Check if domain ends with .wildcard_domain
        # Example: tracker.example.com ends with .tracker.com
        pattern = "\\." wildcard[i] "$"
        if (match(domain, pattern)) {
            is_covered = 1
            break
        }
    }
    
    if (!is_covered) {
        print $0
    }
}
' "$EXACT_FILE" > "$SORTED.tmp"

# Combine wildcards and filtered exact rules
cat "$WILDCARDS_FILE" "$SORTED.tmp" > "$SORTED" 2>/dev/null || cat "$SORTED.tmp" > "$SORTED"

if [[ ! -s "$SORTED" ]]; then
    echo "ERROR: aucune regle apres deduplication intelligente." >&2
    exit 1
fi

TOTAL_LINES=$(wc -l < "$NORMALIZED")
UNIQUE_LINES=$(wc -l < "$SORTED")
DUPLICATES=$((TOTAL_LINES - UNIQUE_LINES))


# ============================================================
# GENERATION combined-filter.txt (AdGuard)
# ============================================================

ADGUARD_TMP="${OUTPUT_ADGUARD}.tmp"

{
    echo "! AdGuard Home - Aggregated DNS Filter"
    echo "! Source lists: ${#FILTER_URLS[@]}"
    echo "! Rules: ${UNIQUE_LINES}"
    echo "! Generated: ${GENERATION_DATE}"
    echo
    cat "$SORTED"
} > "$ADGUARD_TMP"

if [[ ! -s "$ADGUARD_TMP" ]]; then
    echo "ERROR: le fichier AdGuard genere est vide." >&2
    rm -f "$ADGUARD_TMP"
    exit 1
fi

INVALID_ADGUARD=$(
    awk '
    /^!/ { next }
    /^$/ { next }
    /^\|\|\*?[A-Za-z0-9._-]+\^$/ { next }
    /^@@\|\|\*?[A-Za-z0-9._-]+\^$/ { next }
    { print }
    ' "$ADGUARD_TMP"
)

if [[ -n "$INVALID_ADGUARD" ]]; then
    echo "ERROR: regles AdGuard invalides detectees." >&2
    echo
    echo "$INVALID_ADGUARD" | head -20
    echo
    rm -f "$ADGUARD_TMP"
    exit 1
fi


# ============================================================
# GENERATION blocky-filter.txt (Blocky)
# ============================================================

BLOCKY_SORTED_TMP="$TMPDIR/blocky-sorted.txt"

awk \
    -v block_ip="$BLOCK_IP" \
    '
    /^@@\|\|\*?[A-Za-z0-9._-]+\^$/ {
        d = $0
        sub(/^@@\|\|/, "", d)
        sub(/\^$/, "", d)
        allow[tolower(d)] = 1
        next
    }

    /^\|\|\*?[A-Za-z0-9._-]+\^$/ {
        d = $0
        sub(/^\|\|/, "", d)
        sub(/\^$/, "", d)
        block[tolower(d)] = 1
        next
    }

    END {
        for (d in block) {
            if (!(d in allow)) {
                # Blocky format: wildcards without IP, exact domains with IP
                if (d ~ /^\*\./) {
                    print d
                } else {
                    print block_ip " " d
                }
            }
        }
    }
    ' "$SORTED" | LC_ALL=C sort -u > "$BLOCKY_SORTED_TMP"

if [[ ! -s "$BLOCKY_SORTED_TMP" ]]; then
    echo "ERROR: aucune regle Blocky produite." >&2
    rm -f "$ADGUARD_TMP"
    exit 1
fi

BLOCKY_RULES=$(wc -l < "$BLOCKY_SORTED_TMP")
BLOCKY_TMP="${OUTPUT_BLOCKY}.tmp"

{
    echo "# Blocky DNS Filter - Generated from AdGuard rules"
    echo "# Format: hosts"
    echo "# Block IP: $BLOCK_IP"
    echo "# Source lists: ${#FILTER_URLS[@]}"
    echo "# Rules: ${BLOCKY_RULES}"
    echo "# Generated: ${GENERATION_DATE}"
    echo
    cat "$BLOCKY_SORTED_TMP"
} > "$BLOCKY_TMP"

if [[ ! -s "$BLOCKY_TMP" ]]; then
    echo "ERROR: le fichier Blocky genere est vide." >&2
    rm -f "$ADGUARD_TMP" "$BLOCKY_TMP"
    exit 1
fi

INVALID_BLOCKY=$(
    awk '
    /^#/ { next }
    /^$/ { next }
    /^([0-9]{1,3}\.){3}[0-9]{1,3}[[:space:]]+[A-Za-z0-9._-]+$/ { next }
    /^\*\.[A-Za-z0-9._-]+$/ { next }
    { print }
    ' "$BLOCKY_TMP"
)

if [[ -n "$INVALID_BLOCKY" ]]; then
    echo "ERROR: regles Blocky invalides detectees." >&2
    echo
    echo "$INVALID_BLOCKY" | head -20
    echo
    rm -f "$ADGUARD_TMP" "$BLOCKY_TMP"
    exit 1
fi


# ============================================================
# DETECTION CHANGEMENTS
# ============================================================

CHANGED_ADGUARD=1
CHANGED_BLOCKY=1

if [[ -f "$OUTPUT_ADGUARD" ]] && cmp -s "$ADGUARD_TMP" "$OUTPUT_ADGUARD"; then
    CHANGED_ADGUARD=0
fi

if [[ -f "$OUTPUT_BLOCKY" ]] && cmp -s "$BLOCKY_TMP" "$OUTPUT_BLOCKY"; then
    CHANGED_BLOCKY=0
fi

CHANGED=1
if [[ "$CHANGED_ADGUARD" -eq 0 && "$CHANGED_BLOCKY" -eq 0 ]]; then
    CHANGED=0
fi

mv "$ADGUARD_TMP" "$OUTPUT_ADGUARD"
mv "$BLOCKY_TMP" "$OUTPUT_BLOCKY"

# Supprimer le dossier temporaire avant git status pour ne pas afficher
# de fichiers non suivis parasites.
cleanup
trap - EXIT


echo
echo "============================================================"
echo " Aggregation complete"
echo "============================================================"
echo
echo "Generation date    : $GENERATION_DATE"
echo "Source lists       : ${#FILTER_URLS[@]}"
echo "Downloaded         : $DOWNLOADED"
echo "Rules before dedup : $TOTAL_LINES"
echo "Unique rules       : $UNIQUE_LINES"
echo "Duplicates removed : $DUPLICATES"
echo "Blocky rules       : $BLOCKY_RULES"
echo
echo "AdGuard output:"
echo "$OUTPUT_ADGUARD"
echo
echo "Blocky output:"
echo "$OUTPUT_BLOCKY"
echo
echo "============================================================"

if [[ "$CHANGED" -eq 0 ]]; then
    echo
    echo "============================================================"
    echo " Git"
    echo "============================================================"
    echo
    echo "No changes detected."
    echo "No commit."
    echo "No push."
    echo
    echo "============================================================"
    exit 0
fi


# ============================================================
# GIT COMMIT + PUSH
# ============================================================

echo
echo "============================================================"
echo " Git"
echo "============================================================"
echo
echo "Changes detected in:"
echo "  $GIT_FILE_ADGUARD"
echo "  $GIT_FILE_BLOCKY"
echo

git status --short

git add -- "$GIT_FILE_ADGUARD" "$GIT_FILE_BLOCKY"

if git diff --cached --quiet; then
    echo
    echo "No staged changes."
    exit 0
fi

COMMIT_MESSAGE="Update combined-filter.txt and blocky-filter.txt - generated ${GENERATION_DATE}"

echo
echo "Commit message:"
echo "  $COMMIT_MESSAGE"
echo

git commit -m "$COMMIT_MESSAGE"

echo
echo "Pushing to:"
echo "  origin/$GIT_BRANCH"
echo

if git push origin "$GIT_BRANCH"; then
    echo
    echo "============================================================"
    echo " Git push SUCCESS"
    echo "============================================================"
    echo
    echo "Branch : $GIT_BRANCH"
    echo "Remote : $GIT_REMOTE"
    echo "Commit : $COMMIT_MESSAGE"
    echo
    echo "============================================================"
else
    echo
    echo "============================================================"
    echo " ERROR: Git push FAILED"
    echo "============================================================"
    echo
    echo "Les fichiers ont ete generes."
    echo "Le commit existe localement."
    echo
    echo "Pour reessayer :"
    echo
    echo "  cd \"$GIT_REPO_DIR\""
    echo "  git push origin \"$GIT_BRANCH\""
    echo
    echo "============================================================"
    exit 1
fi
