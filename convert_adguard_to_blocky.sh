#!/usr/bin/env bash

set -Eeuo pipefail

# ============================================================
# AdGuard Home → Blocky DNS Filter Converter
# ============================================================
#
# Objectif :
#   - Convertir un fichier de règles AdGuard Home
#   - En format compatible Blocky DNS
#   - Générer un fichier lisible par Blocky
#
# Formats acceptés par Blocky :
#   1. Hosts format     : 0.0.0.0 domain.com
#   2. Simple domains   : domain.com (un par ligne)
#   3. Wildcard format  : *.domain.com (pour v0.23+)
#
# Ce script génère le format Hosts (0.0.0.0) car c'est
# le plus universel et compatible avec toutes les versions.
#
# ============================================================

# ============================================================
# CONFIGURATION
# ============================================================

# Fichier d'entrée (format AdGuard)
INPUT="${1:-}"

# Fichier de sortie (format Blocky)
OUTPUT="${2:-}"

# IP de blocage (par défaut 0.0.0.0)
# Peut être changé en 127.0.0.1 ou toute autre IP locale
BLOCK_IP="${BLOCK_IP:-0.0.0.0}"


# ============================================================
# VALIDATION DES ARGUMENTS
# ============================================================

if [[ -z "$INPUT" ]] || [[ -z "$OUTPUT" ]]; then
    cat >&2 << 'EOF'
Usage: convert_adguard_to_blocky.sh <input_file> <output_file>

Arguments:
  input_file   Fichier de règles AdGuard Home (combined-filter.txt)
  output_file  Fichier de sortie compatible Blocky DNS

Options:
  BLOCK_IP     IP de blocage (défaut: 0.0.0.0)

Examples:
  # Conversion simple
  ./convert_adguard_to_blocky.sh combined-filter.txt blocky-filter.txt

  # Avec IP personnalisée
  BLOCK_IP=127.0.0.1 ./convert_adguard_to_blocky.sh in.txt out.txt

Description:
  Ce script convertit les règles DNS AdGuard Home vers un format
  compatible Blocky (format hosts).

  Format AdGuard:
    ||example.com^
    @@||allowed.com^

  Format Blocky (hosts):
    0.0.0.0 example.com
    (whitelist remplacée par suppression)

EOF
    exit 1
fi


# ============================================================
# VÉRIFICATION DES FICHIERS
# ============================================================

if [[ ! -f "$INPUT" ]]; then
    echo "ERROR: fichier d'entrée introuvable: $INPUT" >&2
    exit 1
fi

if [[ ! -r "$INPUT" ]]; then
    echo "ERROR: fichier d'entrée non lisible: $INPUT" >&2
    exit 1
fi

# Vérifier que le fichier n'est pas vide
if [[ ! -s "$INPUT" ]]; then
    echo "ERROR: fichier d'entrée vide: $INPUT" >&2
    exit 1
fi

# Vérifier le répertoire de sortie
OUTPUT_DIR="$(dirname "$OUTPUT")"

if [[ ! -d "$OUTPUT_DIR" ]]; then
    echo "ERROR: répertoire de sortie inexistant: $OUTPUT_DIR" >&2
    exit 1
fi

if [[ ! -w "$OUTPUT_DIR" ]]; then
    echo "ERROR: répertoire de sortie non accessible en écriture: $OUTPUT_DIR" >&2
    exit 1
fi


# ============================================================
# VÉRIFICATION DU FORMAT DE L'IP
# ============================================================

validate_ip() {
    local ip="$1"
    
    # Format IPv4 basique
    if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    fi
    
    # Format localhost
    if [[ "$ip" == "127.0.0.1" ]] || [[ "$ip" == "localhost" ]]; then
        return 0
    fi
    
    return 1
}

if ! validate_ip "$BLOCK_IP"; then
    echo "ERROR: adresse IP invalide: $BLOCK_IP" >&2
    exit 1
fi


# ============================================================
# STATISTIQUES
# ============================================================

echo
echo "============================================================"
echo " AdGuard → Blocky DNS Filter Converter"
echo "============================================================"
echo
echo "Input  : $INPUT"
echo "Output : $OUTPUT"
echo "Block IP: $BLOCK_IP"
echo


# ============================================================
# CONVERSION
# ============================================================

TEMP_OUTPUT="${OUTPUT}.tmp"

awk \
    -v block_ip="$BLOCK_IP" \
    '
    # --------------------------------------------------------
    # Fonction : vérifier si un domaine est valide
    # --------------------------------------------------------
    
    function is_valid_domain(domain) {
        # Minimum : example.com
        if (domain !~ /^[A-Za-z0-9]/) {
            return 0
        }
        
        # Caractères autorisés
        if (domain !~ /^[A-Za-z0-9._-]+$/) {
            return 0
        }
        
        # Pas de domaine qui commence / finit par un point
        if (domain ~ /^\\./ || domain ~ /\\.$/) {
            return 0
        }
        
        # Pas de double point
        if (domain ~ /\\.\\./) {
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
        if (domain ~ /^[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+$/) {
            return 0
        }
        
        return 1
    }
    
    
    # --------------------------------------------------------
    # Traitement ligne par ligne
    # --------------------------------------------------------
    
    {
        # Nettoyage UTF-8 BOM
        sub(/^\\xef\\xbb\\xbf/, "", $0)
        
        # CRLF
        sub(/\\r$/, "", $0)
        
        # Espaces début / fin
        gsub(/^[[:space:]]+/, "", $0)
        gsub(/[[:space:]]+$/, "", $0)
        
        
        # Ligne vide
        if ($0 == "") {
            next
        }
        
        
        # Commentaires AdGuard
        if ($0 ~ /^!/) {
            next
        }
        
        
        # ============================================================
        # RÈGLES DE BLOCAGE ADGUARD
        #
        # Format : ||domain.tld^
        # ============================================================
        
        if ($0 ~ /^\|\|/) {
            # Ignorer les exceptions (@@||...)
            if ($0 ~ /^@@\|\|/) {
                next
            }
            
            # Extraire le domaine
            domain = $0
            sub(/^\|\|/, "", domain)
            sub(/[\^/$*|[:space:]].*$/, "", domain)
            sub(/\.$/, "", domain)
            
            # Normaliser en minuscules
            domain = tolower(domain)
            
            if (is_valid_domain(domain)) {
                print block_ip " " domain
                next
            }
        }
        
        
        # ============================================================
        # DOMAINES SIMPLES
        #
        # Certaines listes contiennent juste :
        # domain.com
        # ============================================================
        
        if ($0 ~ /^[A-Za-z0-9]/ && $0 !~ /[^A-Za-z0-9._-]/) {
            domain = tolower($0)
            
            if (is_valid_domain(domain)) {
                print block_ip " " domain
                next
            }
        }
    }
    ' "$INPUT" > "$TEMP_OUTPUT"


# ============================================================
# VALIDATION DE LA SORTIE
# ============================================================

if [[ ! -s "$TEMP_OUTPUT" ]]; then
    echo "ERROR: aucun domaine convertis." >&2
    rm -f "$TEMP_OUTPUT"
    exit 1
fi


# ============================================================
# DÉDUPLICATION ET TRI
# ============================================================

TEMP_SORTED="${OUTPUT}.sorted"

LC_ALL=C sort -u "$TEMP_OUTPUT" > "$TEMP_SORTED"

if [[ ! -s "$TEMP_SORTED" ]]; then
    echo "ERROR: aucun domaine après déduplication." >&2
    rm -f "$TEMP_OUTPUT" "$TEMP_SORTED"
    exit 1
fi


# ============================================================
# AJOUT HEADER ET FINALIZATION
# ============================================================

TEMP_FINAL="${OUTPUT}.final"

{
    echo "# Blocky DNS Filter - Generated from AdGuard Home"
    echo "# Format: hosts (0.0.0.0 domain)"
    echo "# Block IP: $BLOCK_IP"
    echo "#"
    echo "# Generated: $(date -u '+%Y-%m-%d %H:%M:%S UTC')"
    echo "#"
    cat "$TEMP_SORTED"
    
} > "$TEMP_FINAL"


# ============================================================
# STATISTIQUES
# ============================================================

INPUT_LINES=$(wc -l < "$INPUT")
OUTPUT_LINES=$(wc -l < "$TEMP_SORTED")
TOTAL_LINES=$(wc -l < "$TEMP_FINAL")

echo "Input lines     : $INPUT_LINES"
echo "Converted rules : $OUTPUT_LINES"
echo "Total output    : $TOTAL_LINES (avec header)"
echo


# ============================================================
# REMPLACEMENT ATOMIQUE
# ============================================================

mv "$TEMP_FINAL" "$OUTPUT"

# Nettoyage des temporaires
rm -f "$TEMP_OUTPUT" "$TEMP_SORTED" "${OUTPUT}.final" "${OUTPUT}.tmp"


# ============================================================
# RÉSULTAT FINAL
# ============================================================

echo "============================================================"
echo " Conversion complete ✓"
echo "============================================================"
echo
echo "Output file:"
echo "  $OUTPUT"
echo
echo "File size: $(du -h "$OUTPUT" | cut -f1)"
echo
echo "Usage in Blocky config.yml:"
echo "---"
echo "blocking:"
echo "  blackLists:"
echo "    ads:"
echo "      - file:///app/blocky-filter.txt"
echo "---"
echo
echo "============================================================"

exit 0
