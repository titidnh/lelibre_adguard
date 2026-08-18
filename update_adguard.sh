#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# AdGuard Home - Aggregated Filter Generator
# ============================================================

# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

# Dossier dans lequel se trouve ce script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Fichier final dans le même dossier que le script
OUTPUT="${SCRIPT_DIR}/combined-filter.txt"

# Nombre maximum de téléchargements simultanés
MAX_PARALLEL=5

# Repository Git = dossier du script
GIT_REPO_DIR="$SCRIPT_DIR"

# Fichier suivi par Git
GIT_FILE="combined-filter.txt"

# ------------------------------------------------------------
# LISTES À AGRÉGER
# ------------------------------------------------------------

FILTER_URLS=(

    # AdGuard DNS filter
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"

    # AdGuard DNS Popup Hosts filter
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt"

    # HaGeZi's Ultimate Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt"

    # HaGeZi's Apple Tracker Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_67.txt"

    # Dandelion Sprout's Anti Push Notifications
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_39.txt"

    # HaGeZi's Anti-Piracy Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_46.txt"

    # HaGeZi's Gambling Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_47.txt"

    # HaGeZi's OPPO & Realme Tracker Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_66.txt"

    # HaGeZi's Samsung Tracker Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt"

    # HaGeZi's Vivo Tracker Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_65.txt"

    # HaGeZi's Windows/Office Tracker Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt"

    # HaGeZi's Xiaomi Tracker Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_60.txt"

    # Phishing URL Blocklist (PhishTank and OpenPhish)
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt"

    # HaGeZi's Badware Hoster Blocklist
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_55.txt"

    # HaGeZi's DNS Rebind Protection
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_71.txt"

    # HaGeZi's The World's Most Abused TLDs
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_56.txt"

    # uBlock₀ filters - Badware risks
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt"

    # Malicious URL Blocklist (URLHaus)
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"

    # OISD Blocklist Big
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt"

    # Liste FR - EasyList France
    "https://easylist-downloads.adblockplus.org/liste_fr.txt"
)

# ------------------------------------------------------------
# CHECKS
# ------------------------------------------------------------

for command in curl awk sort mktemp find wc git cmp date; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: '$command' n'est pas installé." >&2
        exit 1
    fi
done

if [[ ${#FILTER_URLS[@]} -eq 0 ]]; then
    echo "ERROR: aucune liste configurée." >&2
    exit 1
fi

if [[ ! -w "$SCRIPT_DIR" ]]; then
    echo "ERROR: le dossier n'est pas accessible en écriture :"
    echo "$SCRIPT_DIR" >&2
    exit 1
fi

# ------------------------------------------------------------
# GIT CHECK
# ------------------------------------------------------------

if [[ ! -d "${GIT_REPO_DIR}/.git" ]]; then
    echo "ERROR: le dossier n'est pas un repository Git :"
    echo "$GIT_REPO_DIR" >&2
    exit 1
fi

cd "$GIT_REPO_DIR"

if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ERROR: aucun remote 'origin' configuré." >&2
    exit 1
fi

GIT_BRANCH="$(git branch --show-current)"

if [[ -z "$GIT_BRANCH" ]]; then
    echo "ERROR: impossible de déterminer la branche Git actuelle." >&2
    exit 1
fi

GIT_REMOTE="$(git remote get-url origin)"

# ------------------------------------------------------------
# TEMP DIRECTORY
# ------------------------------------------------------------

TMPDIR="$(mktemp -d "${SCRIPT_DIR}/.adguard-filter-tmp-XXXXXX")"

cleanup() {
    rm -rf "$TMPDIR"
}

trap cleanup EXIT

# ------------------------------------------------------------
# GENERATION DATE
# ------------------------------------------------------------

GENERATION_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"

# ------------------------------------------------------------
# HEADER
# ------------------------------------------------------------

echo "============================================================"
echo "AdGuard Home - Filter aggregation"
echo "============================================================"
echo "Generation date    : $GENERATION_DATE"
echo "Script             : $SCRIPT_DIR"
echo "Listes configurées : ${#FILTER_URLS[@]}"
echo "Sortie             : $OUTPUT"
echo
echo "Git repository     : $GIT_REPO_DIR"
echo "Git remote         : $GIT_REMOTE"
echo "Git branch         : $GIT_BRANCH"
echo

# ------------------------------------------------------------
# DOWNLOAD FUNCTION
# ------------------------------------------------------------

download_filter() {
    local index="$1"
    local url="$2"
    local output="$TMPDIR/filter-${index}.txt"

    echo "[${index}] Download : $url"

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
        -o "$output"; then

        echo "[${index}] OK"
        return 0
    fi

    echo "[${index}] FAILED : $url" >&2
    rm -f "$output"
    return 1
}

# ------------------------------------------------------------
# DOWNLOAD ALL LISTS IN PARALLEL
# ------------------------------------------------------------

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

    download_filter \
        "$((i + 1))" \
        "${FILTER_URLS[$i]}" &

    PIDS+=("$!")
done

# Attendre tous les téléchargements restants
for pid in "${PIDS[@]}"; do
    if ! wait "$pid"; then
        FAILED=$((FAILED + 1))
    fi
done

echo
echo "============================================================"
echo "Téléchargements terminés"
echo "============================================================"

DOWNLOADED=$(
    find "$TMPDIR" \
        -type f \
        -name 'filter-*.txt' \
        | wc -l
)

echo "Listes configurées  : ${#FILTER_URLS[@]}"
echo "Listes téléchargées : $DOWNLOADED"
echo "Échecs              : $FAILED"
echo

# ------------------------------------------------------------
# SAFETY
#
# Si une seule liste échoue :
# - on ne touche pas à combined-filter.txt
# - aucun commit
# - aucun push
# ------------------------------------------------------------

if [[ "$FAILED" -ne 0 ]]; then
    echo "ERROR: au moins une liste n'a pas pu être téléchargée." >&2
    echo "Le fichier existant est conservé." >&2
    exit 1
fi

if [[ "$DOWNLOADED" -ne "${#FILTER_URLS[@]}" ]]; then
    echo "ERROR: nombre de fichiers téléchargés incorrect." >&2
    echo "Le fichier existant est conservé." >&2
    exit 1
fi

# ------------------------------------------------------------
# NORMALIZATION
# ------------------------------------------------------------

NORMALIZED="$TMPDIR/normalized.txt"

awk '
{
    # --------------------------------------------------------
    # Nettoyage
    # --------------------------------------------------------

    # Supprimer BOM UTF-8
    sub(/^\xef\xbb\xbf/, "", $0)

    # CRLF -> LF
    sub(/\r$/, "", $0)

    # Trim début
    gsub(/^[[:space:]]+/, "", $0)

    # Trim fin
    gsub(/[[:space:]]+$/, "", $0)

    # Ligne vide
    if ($0 == "") {
        next
    }

    # --------------------------------------------------------
    # Commentaires
    # --------------------------------------------------------

    if ($0 ~ /^!/) {
        next
    }

    if ($0 ~ /^#/) {
        next
    }

    # Métadonnées Adblock Plus
    if ($0 ~ /^\[Adblock Plus/) {
        next
    }

    # --------------------------------------------------------
    # Hosts IPv4
    #
    # 0.0.0.0 example.com
    # 127.0.0.1 example.com
    # --------------------------------------------------------

    if ($0 ~ /^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]+/) {

        split($0, parts, /[[:space:]]+/)

        domain = parts[2]

        # Supprimer commentaire inline
        sub(/[[:space:]]+#.*$/, "", domain)

        if (domain == "") {
            next
        }

        if (domain ~ /^(localhost|localhost\.localdomain|broadcasthost|local)$/) {
            next
        }

        if (domain ~ /^[0-9.]+$/) {
            next
        }

        print "||" domain "^"

        next
    }

    # --------------------------------------------------------
    # Hosts IPv6
    #
    # :: example.com
    # --------------------------------------------------------

    if ($0 ~ /^::[[:space:]]+/) {

        split($0, parts, /[[:space:]]+/)

        domain = parts[2]

        if (domain != "") {
            print "||" domain "^"
        }

        next
    }

    # --------------------------------------------------------
    # Tout le reste est conservé
    #
    # AdGuard
    # uBlock
    # EasyList
    # Regex
    # Exceptions
    # etc.
    # --------------------------------------------------------

    print
}
' "$TMPDIR"/filter-*.txt > "$NORMALIZED"

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------

if [[ ! -s "$NORMALIZED" ]]; then
    echo "ERROR: aucune règle après normalisation." >&2
    exit 1
fi

# ------------------------------------------------------------
# DEDUPLICATION
# ------------------------------------------------------------

SORTED="$TMPDIR/sorted.txt"

LC_ALL=C sort -u "$NORMALIZED" > "$SORTED"

if [[ ! -s "$SORTED" ]]; then
    echo "ERROR: aucune règle après déduplication." >&2
    exit 1
fi

# ------------------------------------------------------------
# STATISTICS
# ------------------------------------------------------------

TOTAL_LINES=$(wc -l < "$NORMALIZED")
UNIQUE_LINES=$(wc -l < "$SORTED")
DUPLICATES=$((TOTAL_LINES - UNIQUE_LINES))

# ------------------------------------------------------------
# BUILD FINAL FILE
# ------------------------------------------------------------

FINAL_TMP="${OUTPUT}.tmp"

{
    echo "! ============================================================"
    echo "! AdGuard Home - Aggregated Filter"
    echo "! Generated: $GENERATION_DATE"
    echo "! Source lists: ${#FILTER_URLS[@]}"
    echo "! Rules: $UNIQUE_LINES"
    echo "! ============================================================"
    echo
    cat "$SORTED"
} > "$FINAL_TMP"

# ------------------------------------------------------------
# VALIDATION
# ------------------------------------------------------------

if [[ ! -s "$FINAL_TMP" ]]; then
    echo "ERROR: le fichier final est vide." >&2
    rm -f "$FINAL_TMP"
    exit 1
fi

# ------------------------------------------------------------
# CHECK IF CONTENT CHANGED
# ------------------------------------------------------------

CHANGED=1

if [[ -f "$OUTPUT" ]] && cmp -s "$FINAL_TMP" "$OUTPUT"; then
    CHANGED=0
fi

# Remplacement atomique
mv "$FINAL_TMP" "$OUTPUT"

# ------------------------------------------------------------
# RESULT
# ------------------------------------------------------------

echo
echo "============================================================"
echo "AGGREGATION COMPLETE"
echo "============================================================"
echo "Generation date    : $GENERATION_DATE"
echo "Source lists       : ${#FILTER_URLS[@]}"
echo "Downloaded         : $DOWNLOADED"
echo "Rules before dedup : $TOTAL_LINES"
echo "Unique rules       : $UNIQUE_LINES"
echo "Duplicates removed : $DUPLICATES"
echo
echo "Output:"
echo "$OUTPUT"
echo "============================================================"

# ------------------------------------------------------------
# GIT - NO CHANGE
# ------------------------------------------------------------

if [[ "$CHANGED" -eq 0 ]]; then

    echo
    echo "============================================================"
    echo "GIT"
    echo "============================================================"
    echo "Aucun changement détecté dans combined-filter.txt."
    echo "Pas de commit."
    echo "Pas de push."
    echo "============================================================"

    exit 0
fi

# ------------------------------------------------------------
# GIT - CHANGE DETECTED
# ------------------------------------------------------------

echo
echo "============================================================"
echo "GIT"
echo "============================================================"
echo "Changement détecté dans $GIT_FILE"
echo

git status --short

# ------------------------------------------------------------
# GIT ADD
# ------------------------------------------------------------

git add -- "$GIT_FILE"

# ------------------------------------------------------------
# CHECK STAGED CHANGES
# ------------------------------------------------------------

if git diff --cached --quiet; then
    echo
    echo "Aucun changement Git à committer."
    exit 0
fi

# ------------------------------------------------------------
# COMMIT
# ------------------------------------------------------------

COMMIT_MESSAGE="Update combined-filter.txt - generated ${GENERATION_DATE}"

echo
echo "Commit :"
echo "$COMMIT_MESSAGE"
echo

git commit -m "$COMMIT_MESSAGE"

# ------------------------------------------------------------
# PUSH
# ------------------------------------------------------------

echo
echo "Push vers origin/$GIT_BRANCH..."
echo

if git push origin "$GIT_BRANCH"; then

    echo
    echo "============================================================"
    echo "GIT PUSH SUCCESS"
    echo "============================================================"
    echo "Branch : $GIT_BRANCH"
    echo "Remote : $GIT_REMOTE"
    echo "Commit : $COMMIT_MESSAGE"
    echo "============================================================"

else

    echo
    echo "============================================================"
    echo "ERROR: GIT PUSH FAILED"
    echo "============================================================"
    echo
    echo "Le fichier local a bien été généré."
    echo "Le commit existe localement mais n'a pas pu être poussé."
    echo
    echo "Tu peux réessayer avec :"
    echo "  cd \"$GIT_REPO_DIR\""
    echo "  git push origin \"$GIT_BRANCH\""
    echo
    echo "============================================================"

    exit 1
fi
