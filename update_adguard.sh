#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# AdGuard Home - Aggregated DNS Filter Generator
# ============================================================
#
# Objectif :
#   - Télécharger toutes les listes configurées
#   - Convertir les formats hosts / AdGuard / EasyList / uBlock
#     vers des règles DNS AdGuard
#   - Supprimer les doublons
#   - Générer un unique fichier :
#         combined-filter.txt
#   - Commit + push automatique dans le repo Git courant
#
# IMPORTANT :
#   Le fichier final contient UNIQUEMENT des règles DNS.
#   Pas d'indentation.
#   Une règle par ligne.
#
# ============================================================


# ------------------------------------------------------------
# CONFIGURATION
# ------------------------------------------------------------

# Dossier contenant ce script
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Fichier final
OUTPUT="${SCRIPT_DIR}/combined-filter.txt"

# Nombre maximum de téléchargements simultanés
MAX_PARALLEL=5

# Repository Git
GIT_REPO_DIR="$SCRIPT_DIR"

# Fichier suivi par Git
GIT_FILE="combined-filter.txt"


# ============================================================
# LISTES À AGRÉGER
# ============================================================
#
# Pour ajouter une liste :
#
#   # Nom de la liste
#   "https://..."
#
# Pour supprimer une liste :
#   supprimer les 2 lignes correspondantes.
#
# ============================================================

FILTER_URLS=(

    # --------------------------------------------------------
    # AdGuard DNS filter
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_1.txt"

    # --------------------------------------------------------
    # AdGuard DNS Popup Hosts filter
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_59.txt"

    # --------------------------------------------------------
    # HaGeZi's Ultimate Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_49.txt"

    # --------------------------------------------------------
    # HaGeZi's Apple Tracker Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_67.txt"

    # --------------------------------------------------------
    # Dandelion Sprout's Anti Push Notifications
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_39.txt"

    # --------------------------------------------------------
    # HaGeZi's Anti-Piracy Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_46.txt"

    # --------------------------------------------------------
    # HaGeZi's Gambling Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_47.txt"

    # --------------------------------------------------------
    # HaGeZi's OPPO & Realme Tracker Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_66.txt"

    # --------------------------------------------------------
    # HaGeZi's Samsung Tracker Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_61.txt"

    # --------------------------------------------------------
    # HaGeZi's Vivo Tracker Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_65.txt"

    # --------------------------------------------------------
    # HaGeZi's Windows/Office Tracker Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_63.txt"

    # --------------------------------------------------------
    # HaGeZi's Xiaomi Tracker Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_60.txt"

    # --------------------------------------------------------
    # Phishing URL Blocklist (PhishTank and OpenPhish)
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_30.txt"

    # --------------------------------------------------------
    # HaGeZi's Badware Hoster Blocklist
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_55.txt"

    # --------------------------------------------------------
    # HaGeZi's DNS Rebind Protection
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_71.txt"

    # --------------------------------------------------------
    # HaGeZi's The World's Most Abused TLDs
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_56.txt"

    # --------------------------------------------------------
    # uBlock₀ filters - Badware risks
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_50.txt"

    # --------------------------------------------------------
    # Malicious URL Blocklist (URLHaus)
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_11.txt"

    # --------------------------------------------------------
    # OISD Blocklist Big
    # --------------------------------------------------------
    "https://adguardteam.github.io/HostlistsRegistry/assets/filter_27.txt"

    # --------------------------------------------------------
    # Liste FR - EasyList France
    # --------------------------------------------------------
    "https://easylist-downloads.adblockplus.org/liste_fr.txt"
)


# ============================================================
# CHECK DES DÉPENDANCES
# ============================================================

for command in curl awk sort mktemp find wc git cmp date; do
    if ! command -v "$command" >/dev/null 2>&1; then
        echo "ERROR: '$command' n'est pas installé." >&2
        exit 1
    fi
done


# ============================================================
# CHECK DU DOSSIER
# ============================================================

if [[ ! -d "$SCRIPT_DIR" ]]; then
    echo "ERROR: dossier du script introuvable." >&2
    exit 1
fi

if [[ ! -w "$SCRIPT_DIR" ]]; then
    echo "ERROR: dossier non accessible en écriture :" >&2
    echo "$SCRIPT_DIR" >&2
    exit 1
fi


# ============================================================
# CHECK GIT
# ============================================================

if [[ ! -d "${GIT_REPO_DIR}/.git" ]]; then
    echo "ERROR: le dossier du script n'est pas un repository Git :" >&2
    echo "$GIT_REPO_DIR" >&2
    exit 1
fi

cd "$GIT_REPO_DIR"


# Vérifier que origin existe
if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ERROR: aucun remote Git 'origin' configuré." >&2
    exit 1
fi


# Branche courante
GIT_BRANCH="$(git branch --show-current)"

if [[ -z "$GIT_BRANCH" ]]; then
    echo "ERROR: impossible de déterminer la branche Git courante." >&2
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
# DATE DE GÉNÉRATION
# ============================================================

GENERATION_DATE="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"


# ============================================================
# HEADER
# ============================================================

echo
echo "============================================================"
echo " AdGuard Home - DNS Filter Aggregator"
echo "============================================================"
echo
echo "Generation date    : $GENERATION_DATE"
echo "Script             : $SCRIPT_DIR"
echo "Output             : $OUTPUT"
echo "Source lists       : ${#FILTER_URLS[@]}"
echo
echo "Git repository     : $GIT_REPO_DIR"
echo "Git branch         : $GIT_BRANCH"
echo "Git remote         : $GIT_REMOTE"
echo
echo "============================================================"
echo


# ============================================================
# DOWNLOAD FUNCTION
# ============================================================

download_filter() {

    local index="$1"
    local url="$2"

    local output
    output="$TMPDIR/filter-${index}.txt"

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


# ============================================================
# DOWNLOAD DES LISTES
# ============================================================

PIDS=()
FAILED=0


for i in "${!FILTER_URLS[@]}"; do

    # Limiter le nombre de téléchargements simultanés
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


# Attendre les téléchargements restants
for pid in "${PIDS[@]}"; do

    if ! wait "$pid"; then
        FAILED=$((FAILED + 1))
    fi

done


# ============================================================
# DOWNLOAD RESULTS
# ============================================================

echo
echo "============================================================"
echo " Download results"
echo "============================================================"

DOWNLOADED=$(
    find "$TMPDIR" \
        -type f \
        -name 'filter-*.txt' \
        | wc -l
)

echo "Configured lists   : ${#FILTER_URLS[@]}"
echo "Downloaded lists   : $DOWNLOADED"
echo "Failed lists       : $FAILED"
echo


# ============================================================
# SAFETY CHECK
#
# Si UNE SEULE liste échoue :
#
#   - ne pas remplacer combined-filter.txt
#   - ne pas faire de commit
#   - ne pas faire de push
#
# Cela évite de publier une liste incomplète.
# ============================================================

if [[ "$FAILED" -ne 0 ]]; then

    echo "ERROR: téléchargement incomplet." >&2
    echo "L'ancien combined-filter.txt est conservé." >&2

    exit 1

fi


if [[ "$DOWNLOADED" -ne "${#FILTER_URLS[@]}" ]]; then

    echo "ERROR: nombre de fichiers téléchargés incorrect." >&2
    echo "L'ancien combined-filter.txt est conservé." >&2

    exit 1

fi


# ============================================================
# NORMALISATION DNS
# ============================================================
#
# Cette étape transforme les différents formats en règles DNS
# AdGuard propres.
#
# Exemples :
#
#   0.0.0.0 example.com
#       =>
#   ||example.com^
#
#   127.0.0.1 tracker.example.com
#       =>
#   ||tracker.example.com^
#
#   ||example.com^$third-party
#       =>
#   ||example.com^
#
#   example.com##.advertisement
#       =>
#   IGNORÉ
#
# ============================================================

NORMALIZED="$TMPDIR/normalized.txt"


awk '

# ------------------------------------------------------------
# Fonction : vérifier si un domaine est valide
# ------------------------------------------------------------

function valid_domain(domain) {

    # Minimum : example.com
    if (domain !~ /^[A-Za-z0-9]/) {
        return 0
    }

    # Caractères autorisés
    if (domain !~ /^[A-Za-z0-9._-]+$/) {
        return 0
    }

    # Pas de domaine qui commence / finit par un point
    if (domain ~ /^\./ || domain ~ /\.$/) {
        return 0
    }

    # Pas de double point
    if (domain ~ /\.\./) {
        return 0
    }

    # Éviter localhost
    if (domain == "localhost") {
        return 0
    }

    if (domain == "localhost.localdomain") {
        return 0
    }

    if (domain == "local") {
        return 0
    }

    # Éviter les IP IPv4
    if (domain ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) {
        return 0
    }

    return 1
}


# ------------------------------------------------------------
# Ligne par ligne
# ------------------------------------------------------------

{

    # --------------------------------------------------------
    # Nettoyage
    # --------------------------------------------------------

    # BOM UTF-8
    sub(/^\xef\xbb\xbf/, "", $0)

    # CRLF
    sub(/\r$/, "", $0)

    # Espaces début / fin
    gsub(/^[[:space:]]+/, "", $0)
    gsub(/[[:space:]]+$/, "", $0)


    # --------------------------------------------------------
    # Ligne vide
    # --------------------------------------------------------

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

    if ($0 ~ /^\[/) {
        next
    }


    # --------------------------------------------------------
    # COSMETIC FILTERS
    #
    # uBlock / EasyList :
    #
    # example.com##.advertisement
    # example.com#@#.advertisement
    # example.com##+js(...)
    #
    # Ces règles ne sont pas utiles pour AdGuard Home DNS.
    # --------------------------------------------------------

    if ($0 ~ /##/) {
        next
    }

    if ($0 ~ /#@#/) {
        next
    }

    if ($0 ~ /#\?#/) {
        next
    }

    if ($0 ~ /#@#/) {
        next
    }


    # --------------------------------------------------------
    # HOSTS IPv4
    #
    # 0.0.0.0 example.com
    # 127.0.0.1 example.com
    #
    # Peut contenir plusieurs domaines sur une ligne.
    # --------------------------------------------------------

    if ($0 ~ /^(0\.0\.0\.0|127\.0\.0\.1)[[:space:]]+/) {

        count = split($0, parts, /[[:space:]]+/)

        for (i = 2; i <= count; i++) {

            domain = parts[i]

            # Commentaire inline
            sub(/#.*/, "", domain)

            if (domain == "") {
                continue
            }

            if (valid_domain(domain)) {
                print "||" tolower(domain) "^"
            }

        }

        next
    }


    # --------------------------------------------------------
    # HOSTS IPv6
    #
    # :: example.com
    # --------------------------------------------------------

    if ($0 ~ /^::[[:space:]]+/) {

        count = split($0, parts, /[[:space:]]+/)

        for (i = 2; i <= count; i++) {

            domain = parts[i]

            if (valid_domain(domain)) {
                print "||" tolower(domain) "^"
            }

        }

        next
    }


    # --------------------------------------------------------
    # ADGUARD / ADBLOCK DOMAIN RULE
    #
    # ||example.com^
    #
    # ||example.com^$third-party
    #
    # @@||example.com^
    #
    # Pour une liste DNS, on extrait uniquement le domaine.
    #
    # Les modifiers sont volontairement supprimés.
    #
    # --------------------------------------------------------

    if ($0 ~ /^(@@)?\|\|/) {

        exception = 0

        if ($0 ~ /^@@\|\|/) {
            exception = 1
            sub(/^@@\|\|/, "", $0)
        }
        else {
            sub(/^\|\|/, "", $0)
        }


        # Extraire uniquement la partie domaine.
        #
        # On s'arrête à :
        #   ^
        #   /
        #   $
        #   *
        #   |
        #   espace
        #

        domain = $0

        sub(/[\^\/$*|[:space:]].*$/, "", domain)


        # Retirer éventuellement un point final
        sub(/\.$/, "", domain)


        if (valid_domain(domain)) {

            domain = tolower(domain)

            if (exception) {
                print "@@||" domain "^"
            }
            else {
                print "||" domain "^"
            }

        }

        next
    }


    # --------------------------------------------------------
    # DOMAINES SIMPLES
    #
    # Certaines listes utilisent simplement :
    #
    # example.com
    #
    # On les transforme en :
    #
    # ||example.com^
    # --------------------------------------------------------

    if ($0 ~ /^[A-Za-z0-9._-]+$/) {

        domain = $0

        if (valid_domain(domain)) {
            print "||" tolower(domain) "^"
        }

        next
    }


    # --------------------------------------------------------
    # TOUT LE RESTE EST IGNORÉ
    #
    # Cela élimine notamment :
    #
    #   ## cosmetic rules
    #   /regex/
    #   example.com/path
    #   ##+js(...)
    #   règles purement navigateur
    #
    # car notre objectif est un référentiel DNS.
    # --------------------------------------------------------

    next
}

' "$TMPDIR"/filter-*.txt > "$NORMALIZED"


# ============================================================
# VALIDATION NORMALISATION
# ============================================================

if [[ ! -s "$NORMALIZED" ]]; then

    echo "ERROR: aucune règle DNS après normalisation." >&2

    exit 1

fi


# ============================================================
# DÉDUPLICATION
# ============================================================

SORTED="$TMPDIR/sorted.txt"

LC_ALL=C sort -u "$NORMALIZED" > "$SORTED"


if [[ ! -s "$SORTED" ]]; then

    echo "ERROR: aucune règle après déduplication." >&2

    exit 1

fi


# ============================================================
# STATISTIQUES
# ============================================================

TOTAL_LINES=$(wc -l < "$NORMALIZED")
UNIQUE_LINES=$(wc -l < "$SORTED")

DUPLICATES=$((TOTAL_LINES - UNIQUE_LINES))


# ============================================================
# CONSTRUCTION DU FICHIER FINAL
# ============================================================
#
# IMPORTANT :
#
# PAS DE DATE ICI.
#
# Sinon le fichier changerait chaque jour même si aucune source
# n'a changé et Git ferait un commit quotidien.
#
# Le timestamp est uniquement utilisé dans le commit Git.
# ============================================================

FINAL_TMP="${OUTPUT}.tmp"


{
    echo "! AdGuard Home - Aggregated DNS Filter"
    echo "! Source lists: ${#FILTER_URLS[@]}"
    echo "! Rules: ${UNIQUE_LINES}"
    echo
    cat "$SORTED"

} > "$FINAL_TMP"


# ============================================================
# VALIDATION FINALE
# ============================================================

if [[ ! -s "$FINAL_TMP" ]]; then

    echo "ERROR: le fichier final est vide." >&2

    rm -f "$FINAL_TMP"

    exit 1

fi


# ============================================================
# VALIDATION DU FORMAT
# ============================================================
#
# Toutes les règles doivent être :
#
#   ||domain.tld^
#
# ou :
#
#   @@||domain.tld^
#
# ============================================================

INVALID_LINES=$(
    awk '
    /^!/ {
        next
    }

    /^$/ {
        next
    }

    /^\|\|[A-Za-z0-9._-]+\^$/ {
        next
    }

    /^@@\|\|[A-Za-z0-9._-]+\^$/ {
        next
    }

    {
        print
    }
    ' "$FINAL_TMP"
)


if [[ -n "$INVALID_LINES" ]]; then

    echo "ERROR: règles DNS invalides détectées." >&2
    echo
    echo "$INVALID_LINES" | head -20
    echo
    echo "Le fichier existant est conservé." >&2

    rm -f "$FINAL_TMP"

    exit 1

fi


# ============================================================
# DÉTECTION DU CHANGEMENT
# ============================================================

CHANGED=1


if [[ -f "$OUTPUT" ]] && cmp -s "$FINAL_TMP" "$OUTPUT"; then

    CHANGED=0

fi


# ============================================================
# REMPLACEMENT ATOMIQUE
# ============================================================

mv "$FINAL_TMP" "$OUTPUT"


# ============================================================
# RESULTAT
# ============================================================

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
echo
echo "Output:"
echo "$OUTPUT"
echo
echo "============================================================"


# ============================================================
# PAS DE CHANGEMENT
# ============================================================

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
# CHANGEMENT DÉTECTÉ
# ============================================================

echo
echo "============================================================"
echo " Git"
echo "============================================================"
echo
echo "Change detected in:"
echo "  $GIT_FILE"
echo


# Afficher l'état
git status --short


# ============================================================
# GIT ADD
# ============================================================

git add -- "$GIT_FILE"


# ============================================================
# VÉRIFIER LE STAGED
# ============================================================

if git diff --cached --quiet; then

    echo
    echo "No staged changes."
    exit 0

fi


# ============================================================
# GIT COMMIT
# ============================================================

COMMIT_MESSAGE="Update combined-filter.txt - generated ${GENERATION_DATE}"


echo
echo "Commit message:"
echo "  $COMMIT_MESSAGE"
echo


git commit \
    -m "$COMMIT_MESSAGE"


# ============================================================
# GIT PUSH
# ============================================================

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
    echo "Le fichier a été généré."
    echo "Le commit existe localement."
    echo
    echo "Pour réessayer :"
    echo
    echo "  cd \"$GIT_REPO_DIR\""
    echo "  git push origin \"$GIT_BRANCH\""
    echo
    echo "============================================================"

    exit 1

fi
