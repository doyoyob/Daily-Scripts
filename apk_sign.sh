#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  apk_sign.sh  —  Batch-sign APKs with a PKCS12 release key
#  Place this script in $HOME (~/).
#
#  Usage (non-interactive): apk_sign.sh [APK_DIR]
#  Usage (interactive):     apk_sign.sh          ← shows directory picker
#
#  Signed APKs land in <APK_DIR>/signed_output/ with original filenames.
#  Run apk_install.sh afterward to push them to the device.
#
#  Requirements: OpenJDK 21, apksigner 0.9 jar, zipalign (optional)
# =============================================================================

set -uo pipefail

# ─── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'

info()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()     { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()   { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
err()    { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
header() { echo -e "\n${BOLD}${CYAN}━━━  $*  ━━━${RESET}"; }
die()    { err "$*"; exit 1; }
blank()  { echo; }

# ─── Banner ───────────────────────────────────────────────────────────────────
echo -e "${BOLD}${CYAN}"
echo "╔══════════════════════════════════════════╗"
echo "║        APK Batch Signer  —  Part 1       ║"
echo "╚══════════════════════════════════════════╝"
echo -e "${RESET}"

# ─── Helper: numbered menu ────────────────────────────────────────────────────
# pick_menu <result_var> "Title" "opt1" "opt2" ... "Enter custom path"
# The LAST option is always the "type manually" sentinel.
pick_menu() {
    local var_name="$1"; shift
    local title="$1";    shift
    local -a opts=("$@")
    local last_idx=$(( ${#opts[@]} - 1 ))

    echo -e "${BOLD}  $title${RESET}"
    local i=0
    for opt in "${opts[@]}"; do
        if [[ "$i" -eq "$last_idx" ]]; then
            echo -e "  ${DIM}[$((i+1))]${RESET} ✏  Enter path manually"
        else
            echo -e "  ${DIM}[$((i+1))]${RESET} $opt"
        fi
        i=$(( i + 1 ))
    done
    blank

    local choice
    while true; do
        read -r -p "  Choice [1-${#opts[@]}]: " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && \
           [[ "$choice" -ge 1 ]]        && \
           [[ "$choice" -le "${#opts[@]}" ]]; then
            break
        fi
        warn "Please enter a number between 1 and ${#opts[@]}."
    done

    local picked="${opts[$(( choice - 1 ))]}"
    if [[ "$choice" -eq "${#opts[@]}" ]]; then
        local manual
        read -r -e -p "  Path: " manual
        manual="${manual/#\~/$HOME}"
        eval "$var_name=\"\$manual\""
    else
        picked="${picked/#\~/$HOME}"
        eval "$var_name=\"\$picked\""
    fi
}

# ─── Dependency check ─────────────────────────────────────────────────────────
header "Dependencies"

java -version &>/dev/null || die "java not found. Install with: pkg install openjdk-21"
JAVA_VER=$(java -version 2>&1 | awk -F '"' '/version/{print $2}')
ok "Java $JAVA_VER"

APKSIGNER_JAR="${APKSIGNER_JAR:-}"
if [[ -z "$APKSIGNER_JAR" ]]; then
    APKSIGNER_JAR=$(find "$PREFIX" "$HOME" /data/local -name "apksigner.jar" 2>/dev/null | head -1 || true)
fi
[[ -f "$APKSIGNER_JAR" ]] || die "apksigner.jar not found. Set env: export APKSIGNER_JAR=/path/to/apksigner.jar"
ok "apksigner: $APKSIGNER_JAR"

USE_ZIPALIGN=false
if command -v zipalign &>/dev/null; then
    ok "zipalign: $(command -v zipalign)"
    USE_ZIPALIGN=true
else
    warn "zipalign not found — APKs will be signed without prior alignment."
fi

# ─── APK directory selection ──────────────────────────────────────────────────
header "APK source directory"

if [[ "${1:-}" != "" ]]; then
    APK_DIR="$(realpath "${1}")"
    info "Using argument: $APK_DIR"
else
    blank
    pick_menu APK_DIR "Where are the APKs to sign?" \
        "~/storage/downloads" \
        "~/storage/downloads/apk" \
        "~ (home directory)" \
        "$(pwd)  ← current directory" \
        "Enter custom path"
    # Strip the display annotation if the current-dir option was chosen
    APK_DIR="${APK_DIR%%  *}"
    APK_DIR="$(realpath "$APK_DIR")"
    blank
    info "Selected: $APK_DIR"
fi

[[ -d "$APK_DIR" ]] || die "Directory not found: $APK_DIR"
OUT_DIR="${OUT_DIR:-$APK_DIR/signed_output}"

# ─── Collect APKs ─────────────────────────────────────────────────────────────
header "Scanning"

mapfile -t APK_LIST < <(
    find "$APK_DIR" -maxdepth 1 -name "*.apk" | sort
)

[[ "${#APK_LIST[@]}" -gt 0 ]] || die "No APK files found in '$APK_DIR'."

info "Found ${#APK_LIST[@]} APK(s):"
for f in "${APK_LIST[@]}"; do echo -e "    ${DIM}•${RESET} $(basename "$f")"; done

# ─── Keystore location picker ─────────────────────────────────────────────────
header "Release keystore"

if [[ -z "${KEYSTORE_PATH:-}" ]]; then
    blank
    pick_menu KS_SEARCH_DIR "Where is your keystore (.p12 / .pfx)?" \
        "~/storage/downloads" \
        "~/storage/downloads/apk" \
        "~ (home directory)" \
        "Enter full keystore path"

    # If a directory was selected, scan for keystore files inside it
    if [[ -d "$KS_SEARCH_DIR" ]]; then
        mapfile -t KS_FOUND < <(
            find "$KS_SEARCH_DIR" -maxdepth 2 \
                \( -name "*.p12" -o -name "*.pfx" -o -name "*.jks" \) \
                | sort
        )
        if [[ "${#KS_FOUND[@]}" -eq 0 ]]; then
            warn "No keystore files found in $KS_SEARCH_DIR."
            read -r -e -p "  Enter full keystore path: " KEYSTORE_PATH
            KEYSTORE_PATH="${KEYSTORE_PATH/#\~/$HOME}"
        elif [[ "${#KS_FOUND[@]}" -eq 1 ]]; then
            KEYSTORE_PATH="${KS_FOUND[0]}"
            ok "Auto-selected: $KEYSTORE_PATH"
        else
            blank
            info "Multiple keystores found — pick one:"
            KS_MENU=("${KS_FOUND[@]}" "Enter path manually")
            pick_menu KEYSTORE_PATH "Select keystore:" "${KS_MENU[@]}"
        fi
    else
        # The "Enter full keystore path" option was chosen; value is already a path
        KEYSTORE_PATH="$KS_SEARCH_DIR"
    fi
fi

KEYSTORE_PATH="${KEYSTORE_PATH/#\~/$HOME}"
[[ -f "$KEYSTORE_PATH" ]] || die "Keystore not found: $KEYSTORE_PATH"
ok "Keystore: $KEYSTORE_PATH"

# ─── Key alias ────────────────────────────────────────────────────────────────
if [[ -z "${KEY_ALIAS:-}" ]]; then
    blank
    read -r -p "  Key alias (leave blank to use the first entry): " KEY_ALIAS
fi

# ─── Password — entered and confirmed once, never re-asked ───────────────────
if [[ -z "${KEY_PASS:-}" ]]; then
    blank
    while true; do
        read -r -s -p "  Keystore password: " KEY_PASS;  echo
        read -r -s -p "  Confirm password:  " KEY_PASS2; echo
        if [[ "$KEY_PASS" == "$KEY_PASS2" ]]; then
            break
        fi
        warn "Passwords do not match — try again."
        blank
    done
fi

ok "Credentials accepted."

# ─── Temp workspace ───────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ─── Sign loop ────────────────────────────────────────────────────────────────
header "Signing"
mkdir -p "$OUT_DIR"

SIGNED_COUNT=0
FAILED_COUNT=0
SIGNED_PATHS=()

for SRC in "${APK_LIST[@]}"; do
    BASE="$(basename "$SRC" .apk)"
    DST="$OUT_DIR/${BASE}.apk"
    TMP_ALIGNED="$TMP_DIR/${BASE}_aligned.apk"

    blank
    info "▶ ${BASE}.apk"

    # 1. zipalign (must happen before signing)
    if [[ "$USE_ZIPALIGN" == true ]]; then
        if ! zipalign -f -p 4 "$SRC" "$TMP_ALIGNED" 2>&1; then
            warn "zipalign failed — signing unaligned copy."
            cp "$SRC" "$TMP_ALIGNED"
        fi
    else
        cp "$SRC" "$TMP_ALIGNED"
    fi

    # 2. Build apksigner args (omit --ks-key-alias when blank)
    SIGN_ARGS=(
        --ks       "$KEYSTORE_PATH"
        --ks-pass  "pass:$KEY_PASS"
        --key-pass "pass:$KEY_PASS"
        --out      "$DST"
    )
    [[ -n "${KEY_ALIAS:-}" ]] && SIGN_ARGS+=(--ks-key-alias "$KEY_ALIAS")
    SIGN_ARGS+=("$TMP_ALIGNED")

    # 3. Sign
    SIGN_OUT=$(java -jar "$APKSIGNER_JAR" sign "${SIGN_ARGS[@]}" 2>&1 || true)
    [[ -n "$SIGN_OUT" ]] && echo "$SIGN_OUT"

    # 4. Check output file exists then verify
    if [[ -f "$DST" ]]; then
        VERIFY=$(java -jar "$APKSIGNER_JAR" verify --verbose "$DST" 2>&1 || true)
        echo "$VERIFY" | grep -E "Verified|WARNING|ERROR" || true
        ok "Signed → $(basename "$DST")"
        SIGNED_PATHS+=("$DST")
        SIGNED_COUNT=$(( SIGNED_COUNT + 1 ))
    else
        err "Output missing — signing failed: ${BASE}.apk"
        FAILED_COUNT=$(( FAILED_COUNT + 1 ))
    fi
done

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Done"
echo -e "  Signed : ${BOLD}${GREEN}${SIGNED_COUNT}${RESET}"
echo -e "  Failed : ${BOLD}${RED}${FAILED_COUNT}${RESET}"
echo -e "  Output : ${BOLD}${OUT_DIR}${RESET}"

if [[ "$SIGNED_COUNT" -gt 0 ]]; then
    blank
    info "To install the signed APKs, run:"
    echo -e "    ${BOLD}~/apk_install.sh \"$OUT_DIR\"${RESET}"
fi
