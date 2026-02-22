#!/bin/bash
# ============================================================================
# Export Apple Notes → Obsidian (Markdown + Images)
# ============================================================================
# Requirements: macOS, Notes.app, pandoc (brew install pandoc), python3
# Usage:        ./export_apple_notes.sh [output_directory]
#
# Features:
#   - Extracts inline base64 images from HTML (no Full Disk Access needed)
#   - Copies non-image files (PDF, audio…) via SQLite + filesystem (FDA needed)
#   - Converts HTML to Markdown with Obsidian-compatible image links
#   - Preserves folder structure, creation/modification dates
#   - Bilingual output (French/English based on system locale)
# ============================================================================

set -uo pipefail

# --- i18n --------------------------------------------------------------------
# Auto-detect language from locale; override with EXPORT_LANG=en or EXPORT_LANG=fr
if [[ "${EXPORT_LANG:-auto}" == "auto" ]]; then
    if [[ "${LANG:-}" == fr* ]] || [[ "${LC_ALL:-}" == fr* ]]; then
        L=fr
    else
        L=en
    fi
else
    L="${EXPORT_LANG}"
fi

# Message function: msg KEY
msg() {
    local key="$1"
    eval "echo \"\${MSG_${key}_${L}:-\${MSG_${key}_en}}\""
}

# --- Messages (en/fr) -------------------------------------------------------
MSG_BANNER_en="Export Apple Notes → Obsidian Markdown"
MSG_BANNER_fr="Export Apple Notes → Obsidian Markdown"
MSG_BANNER_SUB_en="(base64 extraction + SQLite filesystem)"
MSG_BANNER_SUB_fr="(extraction base64 + SQLite filesystem)"
MSG_MISSING_PANDOC_en="pandoc is not installed. Run: brew install pandoc"
MSG_MISSING_PANDOC_fr="pandoc n'est pas installé. Lancer : brew install pandoc"
MSG_MISSING_PYTHON_en="python3 is not installed."
MSG_MISSING_PYTHON_fr="python3 n'est pas installé."
MSG_FDA_OK_en="Full Disk Access: OK"
MSG_FDA_OK_fr="Full Disk Access : OK"
MSG_FDA_NO_en="Full Disk Access: not available"
MSG_FDA_NO_fr="Full Disk Access : non disponible"
MSG_FDA_INLINE_en="  → Inline images will be extracted from HTML (OK)"
MSG_FDA_INLINE_fr="  → Les images inline seront extraites du HTML (OK)"
MSG_FDA_NOPDF_en="  → PDF/audio files will NOT be exported"
MSG_FDA_NOPDF_fr="  → Les fichiers PDF/audio ne seront PAS exportés"
MSG_FDA_HINT_en="  → To export everything: System Settings > Privacy > Full Disk Access"
MSG_FDA_HINT_fr="  → Pour tout exporter : Réglages Système > Confidentialité > Accès complet au disque"
MSG_COPYING_DB_en="Copying NoteStore.sqlite..."
MSG_COPYING_DB_fr="Copie de NoteStore.sqlite..."
MSG_BUILDING_MAP_en="Building attachment lookup table..."
MSG_BUILDING_MAP_fr="Construction de la table des pièces jointes..."
MSG_MEDIA_FOUND_en="Files referenced in database"
MSG_MEDIA_FOUND_fr="Fichiers référencés dans la base"
MSG_INVENTORY_en="Scanning Apple Notes..."
MSG_INVENTORY_fr="Inventaire des notes Apple Notes en cours..."
MSG_NOTES_FOUND_en="Notes found"
MSG_NOTES_FOUND_fr="Notes trouvées"
MSG_NOTES_LOCKED_en="Locked notes (skipped)"
MSG_NOTES_LOCKED_fr="Notes verrouillées (ignorées)"
MSG_NOTES_EXPORT_en="Notes to export"
MSG_NOTES_EXPORT_fr="Notes à exporter"
MSG_NO_NOTES_en="No notes to export!"
MSG_NO_NOTES_fr="Aucune note à exporter !"
MSG_STARTING_en="Starting export..."
MSG_STARTING_fr="Début de l'export..."
MSG_REPORT_en="Export Report"
MSG_REPORT_fr="Rapport d'export"
MSG_DONE_en="Export complete!"
MSG_DONE_fr="Export terminé !"
MSG_EXPORTED_en="Notes exported"
MSG_EXPORTED_fr="Notes exportées"
MSG_EMPTY_en="Empty notes"
MSG_EMPTY_fr="Notes vides"
MSG_ERRORS_en="Errors"
MSG_ERRORS_fr="Erreurs"
MSG_B64_en="Base64 images extracted"
MSG_B64_fr="Images base64 extraites"
MSG_FSCOPY_en="Files copied (PDF, audio…)"
MSG_FSCOPY_fr="Fichiers copiés (PDF, audio…)"
MSG_FSMISS_en="Files not found"
MSG_FSMISS_fr="Fichiers non trouvés"
MSG_FOLDER_DIST_en="Distribution by folder:"
MSG_FOLDER_DIST_fr="Répartition par dossier :"
MSG_MEDIA_TYPES_en="Exported media by type:"
MSG_MEDIA_TYPES_fr="Médias exportés par type :"
MSG_TOTAL_SIZE_en="Total size"
MSG_TOTAL_SIZE_fr="Taille totale"
MSG_ICLOUD_HINT_en="(Some files may be in iCloud and not downloaded locally)"
MSG_ICLOUD_HINT_fr="(Certains fichiers peuvent être sur iCloud et pas téléchargés localement)"
MSG_FDA_RERUN_en="Note: PDF and audio files not exported (no Full Disk Access). Enable FDA and re-run for a complete export."
MSG_FDA_RERUN_fr="Note : PDF et fichiers audio non exportés (pas de Full Disk Access). Activer FDA puis relancer pour un export complet."
MSG_EXPORT_FAIL_en="Export failed"
MSG_EXPORT_FAIL_fr="Échec export"
MSG_COPY_FAIL_en="Copy failed"
MSG_COPY_FAIL_fr="Copie échouée"
MSG_FILE_MISSING_en="File not found"
MSG_FILE_MISSING_fr="Fichier introuvable"

# --- Configuration -----------------------------------------------------------
OUTPUT_DIR="${1:-$HOME/Desktop/AppleNotes_Export}"
TIMESTAMP=$(date +"%Y%m%d_%H%M%S")
LOG_FILE="${OUTPUT_DIR}/_export_log_${TIMESTAMP}.txt"
ERRORS_FILE="${OUTPUT_DIR}/_export_errors_${TIMESTAMP}.txt"
STATS_FILE="${OUTPUT_DIR}/_export_stats_${TIMESTAMP}.txt"
ATTACHMENTS_SUBDIR="_attachments"
TMPDIR_EXPORT=$(mktemp -d)
NOTES_DATA_DIR="$HOME/Library/Group Containers/group.com.apple.notes"

# --- Colors ------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# --- Cleanup on exit ---------------------------------------------------------
cleanup() { rm -rf "$TMPDIR_EXPORT"; }
trap cleanup EXIT

# --- Utility functions -------------------------------------------------------
log()   { echo -e "${GREEN}[INFO]${NC} $1";   echo "[INFO] $(date +%H:%M:%S) $1" >> "$LOG_FILE"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $1";  echo "[WARN] $(date +%H:%M:%S) $1" >> "$LOG_FILE"; }
error() { echo -e "${RED}[ERROR]${NC} $1";     echo "[ERROR] $(date +%H:%M:%S) $1" >> "$ERRORS_FILE"; }

sanitize_filename() {
    echo "$1" | sed 's/[\/\\:*?"<>|#]/-/g' | sed 's/  */ /g' | sed 's/^[. ]*//' | sed 's/[. ]*$//' | cut -c1-200
}

# --- Banner ------------------------------------------------------------------
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  $(msg BANNER)${NC}"
echo -e "${BLUE}  $(msg BANNER_SUB)${NC}"
echo -e "${BLUE}============================================${NC}"
echo ""

# --- Prerequisites -----------------------------------------------------------
if ! command -v pandoc &> /dev/null; then
    echo -e "${RED}$(msg MISSING_PANDOC)${NC}"; exit 1
fi
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}$(msg MISSING_PYTHON)${NC}"; exit 1
fi

# --- Full Disk Access check (non-blocking) -----------------------------------
HAS_FDA=false
if ls "$NOTES_DATA_DIR/" &>/dev/null 2>&1; then
    HAS_FDA=true
    echo -e "${GREEN}$(msg FDA_OK)${NC}"
else
    echo -e "${YELLOW}$(msg FDA_NO)${NC}"
    echo -e "${YELLOW}$(msg FDA_INLINE)${NC}"
    echo -e "${YELLOW}$(msg FDA_NOPDF)${NC}"
    echo -e "${YELLOW}$(msg FDA_HINT)${NC}"
fi
echo ""

# --- Init --------------------------------------------------------------------
mkdir -p "$OUTPUT_DIR"
touch "$LOG_FILE"
touch "$ERRORS_FILE"

log "pandoc: $(pandoc --version | head -1)"
log "Full Disk Access: $HAS_FDA"
log "Output: $OUTPUT_DIR"

# --- Phase 1: Build media map from SQLite (if FDA available) -----------------
MEDIA_MAP="${TMPDIR_EXPORT}/media_map.tsv"
touch "$MEDIA_MAP"
TOTAL_MEDIA_DB=0

if [ "$HAS_FDA" = true ]; then
    log "$(msg COPYING_DB)"
    NOTES_DB="${TMPDIR_EXPORT}/NoteStore.sqlite"
    cp "${NOTES_DATA_DIR}/NoteStore.sqlite" "$NOTES_DB" 2>/dev/null || true
    [ -f "${NOTES_DATA_DIR}/NoteStore.sqlite-wal" ] && cp "${NOTES_DATA_DIR}/NoteStore.sqlite-wal" "${NOTES_DB}-wal" 2>/dev/null || true
    [ -f "${NOTES_DATA_DIR}/NoteStore.sqlite-shm" ] && cp "${NOTES_DATA_DIR}/NoteStore.sqlite-shm" "${NOTES_DB}-shm" 2>/dev/null || true

    if [ -f "$NOTES_DB" ]; then
        log "$(msg BUILDING_MAP)"
        sqlite3 -separator $'\t' "$NOTES_DB" <<'SQL' > "$MEDIA_MAP" 2>/dev/null || true
SELECT
    n.Z_PK, a.ZIDENTIFIER, m.ZIDENTIFIER, m.ZFILENAME, acc.ZIDENTIFIER, m.ZTYPEUTI
FROM ZICCLOUDSYNCINGOBJECT n
JOIN ZICCLOUDSYNCINGOBJECT a   ON a.ZNOTE = n.Z_PK AND a.Z_ENT = 5
JOIN ZICCLOUDSYNCINGOBJECT m   ON a.ZMEDIA = m.Z_PK AND m.Z_ENT = 11
JOIN ZICCLOUDSYNCINGOBJECT acc ON n.ZACCOUNT7 = acc.Z_PK AND acc.Z_ENT = 14
WHERE n.Z_ENT = 12
  AND m.ZFILENAME IS NOT NULL AND m.ZFILENAME != ''
ORDER BY n.Z_PK;
SQL
        TOTAL_MEDIA_DB=$(wc -l < "$MEDIA_MAP" | tr -d ' ')
        log "$(msg MEDIA_FOUND): $TOTAL_MEDIA_DB"
    fi
fi

# --- Python base64 extraction script ----------------------------------------
EXTRACT_SCRIPT="${TMPDIR_EXPORT}/extract_base64.py"
cat > "$EXTRACT_SCRIPT" << 'PYEOF'
#!/usr/bin/env python3
"""Extract base64-encoded images from HTML, save as files, rewrite src attributes."""
import re, base64, os, sys, json

html_file = sys.argv[1]
out_dir = sys.argv[2]
rel_prefix = sys.argv[3]

with open(html_file, "r", errors="replace") as f:
    html = f.read()

pattern = r'src="data:(image/([a-zA-Z+]+)|application/([a-zA-Z.-]+));base64,([^"]+)"'
results = []
counter = 0

def replacer(match):
    global counter
    counter += 1
    full_mime = match.group(1)
    img_ext = match.group(2)
    app_ext = match.group(3)
    b64data = match.group(4)

    if img_ext:
        ext = img_ext.replace("+xml", "").replace("svg+xml", "svg")
        if ext == "jpeg": ext = "jpg"
    elif app_ext:
        ext = app_ext.split(".")[-1]
    else:
        ext = "bin"

    filename = f"image_{counter}.{ext}"
    filepath = os.path.join(out_dir, filename)

    try:
        data = base64.b64decode(b64data)
        os.makedirs(out_dir, exist_ok=True)
        with open(filepath, "wb") as f:
            f.write(data)
        results.append({"file": filename, "size": len(data), "type": full_mime})
        return f'src="{rel_prefix}/{filename}"'
    except Exception as e:
        results.append({"file": filename, "error": str(e)})
        return match.group(0)

new_html = re.sub(pattern, replacer, html)

with open(html_file, "w") as f:
    f.write(new_html)

print(json.dumps({"extracted": len(results), "files": results}))
PYEOF

# --- Phase 2: Inventory via AppleScript --------------------------------------
log "$(msg INVENTORY)"

INVENTORY_FILE="${TMPDIR_EXPORT}/inventory.tsv"

osascript <<APPLESCRIPT > "$INVENTORY_FILE"
set theDelim to (ASCII character 9)

tell application "Notes"
    set output to ""
    set allAccounts to every account
    repeat with anAccount in allAccounts
        set accountName to name of anAccount
        set allFolders to every folder of anAccount
        repeat with aFolder in allFolders
            set folderName to name of aFolder
            set folderPath to accountName & "/" & folderName

            set allNotes to every note of aFolder
            repeat with aNote in allNotes
                try
                    set noteName to name of aNote
                    set noteId to id of aNote
                    set noteCreation to creation date of aNote as string
                    set noteMod to modification date of aNote as string
                    set isLocked to password protected of aNote
                    set attachCount to count of attachments of aNote

                    set output to output & folderPath & theDelim & noteName & theDelim & noteId & theDelim & noteCreation & theDelim & noteMod & theDelim & (isLocked as string) & theDelim & (attachCount as string) & linefeed
                on error errMsg
                    -- skip
                end try
            end repeat
        end repeat
    end repeat
    return output
end tell
APPLESCRIPT

TOTAL_NOTES=$(grep -c $'\t' "$INVENTORY_FILE" || true)
LOCKED_NOTES=$(awk -F'\t' '$6 == "true"' "$INVENTORY_FILE" | wc -l | tr -d ' ')
EXPORTABLE_NOTES=$((TOTAL_NOTES - LOCKED_NOTES))

echo ""
log "$(msg NOTES_FOUND): $TOTAL_NOTES"
log "$(msg NOTES_LOCKED): $LOCKED_NOTES"
log "$(msg NOTES_EXPORT): $EXPORTABLE_NOTES"
echo ""

if [ "$EXPORTABLE_NOTES" -eq 0 ]; then
    error "$(msg NO_NOTES)"
    exit 1
fi

# --- Phase 3: Export each note -----------------------------------------------
log "$(msg STARTING)"
echo ""

COUNTER=0
SUCCESS=0
FAILED=0
EMPTY=0
BASE64_IMAGES=0
FS_MEDIA_COPIED=0
FS_MEDIA_MISSING=0

while IFS=$'\t' read -r FOLDER_PATH NOTE_NAME NOTE_ID CREATION_DATE MOD_DATE IS_LOCKED ATTACH_COUNT; do

    [ -z "$NOTE_NAME" ] && continue
    [ "$IS_LOCKED" = "true" ] && continue

    COUNTER=$((COUNTER + 1))

    SAFE_NAME=$(sanitize_filename "$NOTE_NAME")
    [ -z "$SAFE_NAME" ] && SAFE_NAME="Untitled_${COUNTER}"

    SAFE_FOLDER=$(echo "$FOLDER_PATH" | sed 's/[\\:*?"<>|#]/-/g')
    DEST_DIR="${OUTPUT_DIR}/${SAFE_FOLDER}"
    mkdir -p "$DEST_DIR"

    NOTE_ATTACHMENTS_DIR="${DEST_DIR}/${ATTACHMENTS_SUBDIR}/${SAFE_NAME}"
    MD_FILE="${DEST_DIR}/${SAFE_NAME}.md"

    # Handle duplicate names
    if [ -f "$MD_FILE" ]; then
        SUFFIX=2
        while [ -f "${DEST_DIR}/${SAFE_NAME}_${SUFFIX}.md" ]; do
            SUFFIX=$((SUFFIX + 1))
        done
        SAFE_NAME="${SAFE_NAME}_${SUFFIX}"
        MD_FILE="${DEST_DIR}/${SAFE_NAME}.md"
        NOTE_ATTACHMENTS_DIR="${DEST_DIR}/${ATTACHMENTS_SUBDIR}/${SAFE_NAME}"
    fi

    # Progress
    DISPLAY_NAME="${NOTE_NAME:0:55}"
    printf "\r\033[K  [%d/%d] %s" "$COUNTER" "$EXPORTABLE_NOTES" "$DISPLAY_NAME"

    # -------------------------------------------------------------------
    # A) Extract HTML via AppleScript
    # -------------------------------------------------------------------
    HTML_FILE="${TMPDIR_EXPORT}/note_html.tmp"
    rm -f "$HTML_FILE"

    osascript - "$NOTE_ID" <<'APPLESCRIPT_BODY' > "$HTML_FILE" 2>/dev/null || true
on run argv
    set noteId to item 1 of argv
    tell application "Notes"
        try
            set theNote to note id noteId
            return body of theNote
        on error errMsg
            return "__EXPORT_ERROR__: " & errMsg
        end try
    end tell
end run
APPLESCRIPT_BODY

    if [ -f "$HTML_FILE" ] && [ -s "$HTML_FILE" ]; then
        HEAD=$(head -c 100 "$HTML_FILE")
        if [[ "$HEAD" == *"__EXPORT_ERROR__"* ]]; then
            error "$(msg EXPORT_FAIL) '$NOTE_NAME': $(cat "$HTML_FILE")"
            FAILED=$((FAILED + 1))
            continue
        fi
    else
        # Retry by name
        osascript - "$NOTE_NAME" <<'APPLESCRIPT_FALLBACK' > "$HTML_FILE" 2>/dev/null || true
on run argv
    set targetName to item 1 of argv
    tell application "Notes"
        try
            set allNotes to every note whose name is targetName
            if (count of allNotes) > 0 then
                return body of item 1 of allNotes
            else
                return "__EXPORT_ERROR__: Note not found"
            end if
        on error errMsg
            return "__EXPORT_ERROR__: " & errMsg
        end try
    end tell
end run
APPLESCRIPT_FALLBACK
        if [ ! -s "$HTML_FILE" ]; then
            error "$(msg EXPORT_FAIL) '$NOTE_NAME': empty HTML"
            FAILED=$((FAILED + 1))
            continue
        fi
        HEAD=$(head -c 100 "$HTML_FILE")
        if [[ "$HEAD" == *"__EXPORT_ERROR__"* ]]; then
            error "$(msg EXPORT_FAIL) '$NOTE_NAME': $(cat "$HTML_FILE")"
            FAILED=$((FAILED + 1))
            continue
        fi
    fi

    HTML_SIZE=$(stat -f%z "$HTML_FILE" 2>/dev/null || echo "0")
    if [ "$HTML_SIZE" -lt 30 ]; then
        EMPTY=$((EMPTY + 1))
    fi

    # -------------------------------------------------------------------
    # B) Extract base64 images from HTML → separate files
    # -------------------------------------------------------------------
    NOTE_IMG_COUNT=0
    REL_PREFIX="${ATTACHMENTS_SUBDIR}/${SAFE_NAME}"

    EXTRACT_RESULT=$(python3 "$EXTRACT_SCRIPT" "$HTML_FILE" "$NOTE_ATTACHMENTS_DIR" "$REL_PREFIX" 2>/dev/null || echo '{"extracted":0}')
    EXTRACTED=$(echo "$EXTRACT_RESULT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('extracted',0))" 2>/dev/null || echo "0")

    if [ "$EXTRACTED" -gt 0 ]; then
        NOTE_IMG_COUNT=$EXTRACTED
        BASE64_IMAGES=$((BASE64_IMAGES + EXTRACTED))
    fi

    # -------------------------------------------------------------------
    # C) Non-image files via SQLite + filesystem (PDF, audio, etc.)
    # -------------------------------------------------------------------
    if [ "$HAS_FDA" = true ] && [ -s "$MEDIA_MAP" ]; then
        NOTE_ZPK=$(echo "$NOTE_ID" | grep -oE '/p[0-9]+$' | tr -d '/p')

        if [ -n "${NOTE_ZPK:-}" ]; then
            while IFS=$'\t' read -r _NZ ATTACH_IDENT MEDIA_IDENT MEDIA_FILE ACCT_UUID MEDIA_UTI; do
                [ -z "$MEDIA_FILE" ] && continue

                # Skip image types — already handled by base64 extraction
                case "${MEDIA_UTI:-}" in
                    public.jpeg|public.png|public.gif|public.tiff|public.heic|com.compuserve.gif|public.svg-image)
                        continue ;;
                esac

                MEDIA_SRC="${NOTES_DATA_DIR}/Accounts/${ACCT_UUID}/Media/${MEDIA_IDENT}/${MEDIA_FILE}"
                SAFE_MEDIA_NAME=$(sanitize_filename "$MEDIA_FILE")
                [ -z "$SAFE_MEDIA_NAME" ] && SAFE_MEDIA_NAME="file_${FS_MEDIA_COPIED}"

                # Deduplicate filenames
                if [ -f "${NOTE_ATTACHMENTS_DIR}/${SAFE_MEDIA_NAME}" ]; then
                    BASE="${SAFE_MEDIA_NAME%.*}"
                    EXT="${SAFE_MEDIA_NAME##*.}"
                    DSUFFIX=2
                    while [ -f "${NOTE_ATTACHMENTS_DIR}/${BASE}_${DSUFFIX}.${EXT}" ]; do
                        DSUFFIX=$((DSUFFIX + 1))
                    done
                    SAFE_MEDIA_NAME="${BASE}_${DSUFFIX}.${EXT}"
                fi

                ATTACH_DEST="${NOTE_ATTACHMENTS_DIR}/${SAFE_MEDIA_NAME}"

                if [ -f "$MEDIA_SRC" ]; then
                    mkdir -p "$NOTE_ATTACHMENTS_DIR"
                    if cp "$MEDIA_SRC" "$ATTACH_DEST" 2>/dev/null; then
                        FS_MEDIA_COPIED=$((FS_MEDIA_COPIED + 1))
                        NOTE_IMG_COUNT=$((NOTE_IMG_COUNT + 1))
                    else
                        FS_MEDIA_MISSING=$((FS_MEDIA_MISSING + 1))
                        warn "$(msg COPY_FAIL): '$MEDIA_FILE' in '$NOTE_NAME'"
                    fi
                else
                    FS_MEDIA_MISSING=$((FS_MEDIA_MISSING + 1))
                    warn "$(msg FILE_MISSING): '$MEDIA_FILE' (${MEDIA_IDENT}) in '$NOTE_NAME'"
                fi
            done < <(awk -F'\t' -v zpk="$NOTE_ZPK" '$1 == zpk' "$MEDIA_MAP")
        fi
    fi

    # Remove empty attachment dir
    if [ -d "$NOTE_ATTACHMENTS_DIR" ] && [ -z "$(ls -A "$NOTE_ATTACHMENTS_DIR" 2>/dev/null)" ]; then
        rmdir "$NOTE_ATTACHMENTS_DIR" 2>/dev/null || true
    fi

    # -------------------------------------------------------------------
    # D) Convert HTML → Markdown via pandoc
    # -------------------------------------------------------------------
    MD_CONTENT_FILE="${TMPDIR_EXPORT}/note_md.tmp"
    pandoc -f html -t markdown_strict+pipe_tables+backtick_code_blocks+fenced_code_blocks --wrap=none "$HTML_FILE" > "$MD_CONTENT_FILE" 2>/dev/null || cp "$HTML_FILE" "$MD_CONTENT_FILE"

    # Obsidian image syntax
    if [ "$NOTE_IMG_COUNT" -gt 0 ]; then
        sed -i '' -E "s/!\[([^]]*)\]\((${ATTACHMENTS_SUBDIR}\/[^)]+)\)/![[\2]]/g" "$MD_CONTENT_FILE" 2>/dev/null || true
    fi

    # -------------------------------------------------------------------
    # E) Write Markdown file with YAML frontmatter
    # -------------------------------------------------------------------
    YAML_TITLE=$(echo "$NOTE_NAME" | sed 's/"/\\"/g')

    {
        echo "---"
        echo "title: \"${YAML_TITLE}\""
        echo "created: \"${CREATION_DATE}\""
        echo "modified: \"${MOD_DATE}\""
        echo "source: \"Apple Notes\""
        echo "apple_notes_id: \"${NOTE_ID}\""
        echo "attachments: ${NOTE_IMG_COUNT}"
        echo "export_date: \"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\""
        echo "---"
        echo ""
        cat "$MD_CONTENT_FILE"
    } > "$MD_FILE"

    SUCCESS=$((SUCCESS + 1))

done < "$INVENTORY_FILE"

echo ""
echo ""

# --- Phase 4: Report --------------------------------------------------------
echo -e "${BLUE}============================================${NC}"
echo -e "${BLUE}  $(msg REPORT)${NC}"
echo -e "${BLUE}============================================${NC}"

TOTAL_MEDIA=$((BASE64_IMAGES + FS_MEDIA_COPIED))

cat > "$STATS_FILE" << STATS
Export Apple Notes - Report
=============================
Date: $(date)
Output: $OUTPUT_DIR
Full Disk Access: $HAS_FDA

--- Notes ---
Total notes found: $TOTAL_NOTES
Locked notes (skipped): $LOCKED_NOTES
Notes exported: $SUCCESS
Empty notes: $EMPTY
Errors: $FAILED

--- Media ---
Base64 images extracted: $BASE64_IMAGES
Files copied from filesystem: $FS_MEDIA_COPIED
Total media exported: $TOTAL_MEDIA
Files not found: $FS_MEDIA_MISSING
STATS

echo ""
log "$(msg DONE)"
log "   $(msg EXPORTED): $SUCCESS"
log "   $(msg EMPTY): $EMPTY"
log "   $(msg ERRORS): $FAILED"
log "   $(msg B64): $BASE64_IMAGES"
log "   $(msg FSCOPY): $FS_MEDIA_COPIED"
log "   $(msg FSMISS): $FS_MEDIA_MISSING"
echo ""
log "   Output → $OUTPUT_DIR"
log "   Log    → $LOG_FILE"
log "   Stats  → $STATS_FILE"
echo ""

echo -e "${BLUE}$(msg FOLDER_DIST)${NC}"
find "$OUTPUT_DIR" -name "*.md" -print0 | xargs -0 -I{} dirname {} | sort | uniq -c | sort -rn | head -20

if [ "$TOTAL_MEDIA" -gt 0 ]; then
    echo ""
    echo -e "${BLUE}$(msg MEDIA_TYPES)${NC}"
    find "$OUTPUT_DIR" -path "*/${ATTACHMENTS_SUBDIR}/*" -type f 2>/dev/null | sed 's/.*\.//' | sort | uniq -c | sort -rn
fi

TOTAL_SIZE=$(du -sh "$OUTPUT_DIR" 2>/dev/null | cut -f1)
echo ""
echo -e "${GREEN}$(msg TOTAL_SIZE): ${TOTAL_SIZE}${NC}"

if [ "$FS_MEDIA_MISSING" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}$FS_MEDIA_MISSING $(msg FSMISS).${NC}"
    echo -e "${YELLOW}$(msg ICLOUD_HINT)${NC}"
fi

if [ "$HAS_FDA" = false ] && [ "$TOTAL_MEDIA_DB" -gt 0 ]; then
    echo ""
    echo -e "${YELLOW}$(msg FDA_RERUN)${NC}"
fi

echo ""
