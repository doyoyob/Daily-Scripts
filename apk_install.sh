#!/data/data/com.termux/files/usr/bin/bash
# =============================================================================
#  apk_install.sh  —  Install signed APKs via rish (Shizuku) or adb
#  Place this script in $HOME (~/).
#
#  Usage (non-interactive): apk_install.sh [APK_DIR]
#  Usage (interactive):     apk_install.sh          ← shows directory picker
#
#  rish/Shizuku is tried first; falls back to adb per-APK on failure.
#  APKs are staged to /data/local/tmp before pm install so the Android
#  shell user can read them (Termux home is not world-readable).
#
#  Requirements: rish + rish_shizuku.dex in PATH, and/or adb
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
echo "║      APK Batch Installer  —  Part 2      ║"
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

# ─── APK directory selection ──────────────────────────────────────────────────
header "APK directory"

# Common locations: the signed_output dirs next to typical APK sources,
# and generic Downloads locations.
DOWNLOADS="$HOME/storage/downloads"
DEFAULT_SIGNED="$DOWNLOADS/signed_output"
HOME_SIGNED="$HOME/signed_output"

if [[ "${1:-}" != "" ]]; then
    APK_DIR="$(realpath "${1}")"
    info "Using argument: $APK_DIR"
else
    blank
    pick_menu APK_DIR "Where are the signed APKs to install?" \
        "~/storage/downloads/signed_output  ← default sign output" \
        "~/storage/downloads" \
        "~/storage/downloads/apk" \
        "~/signed_output" \
        "~ (home directory)" \
        "$(pwd)  ← current directory" \
        "Enter custom path"
    # Strip display annotations
    APK_DIR="${APK_DIR%%  *}"
    APK_DIR="$(realpath "$APK_DIR")"
    blank
    info "Selected: $APK_DIR"
fi

[[ -d "$APK_DIR" ]] || die "Directory not found: $APK_DIR"

# ─── Collect APKs ─────────────────────────────────────────────────────────────
header "Scanning"

mapfile -t APK_LIST < <(find "$APK_DIR" -maxdepth 1 -name "*.apk" | sort)

[[ "${#APK_LIST[@]}" -gt 0 ]] || die "No APK files found in '$APK_DIR'."

info "Found ${#APK_LIST[@]} APK(s) to install:"
for f in "${APK_LIST[@]}"; do echo -e "    ${DIM}•${RESET} $(basename "$f")"; done

# ─── Detect install method ────────────────────────────────────────────────────
header "Install method"

USE_RISH=false
ADB_AVAILABLE=false

# ── rish / Shizuku ────────────────────────────────────────────────────────────
if command -v rish &>/dev/null; then
    info "rish found — probing Shizuku …"
    RISH_TEST=$(rish -c "echo __shizuku_ok__" 2>&1 || true)
    if echo "$RISH_TEST" | grep -q "__shizuku_ok__"; then
        ok "Shizuku responsive. Primary method: rish."
        USE_RISH=true
    else
        warn "Shizuku probe failed (${RISH_TEST:-<no output>})."
        warn "Will use adb instead."
    fi
else
    warn "rish not found in PATH."
fi

# ── adb (fallback or sole method) ────────────────────────────────────────────
if command -v adb &>/dev/null; then
    ADB_AVAILABLE=true
fi

if [[ "$USE_RISH" == false && "$ADB_AVAILABLE" == false ]]; then
    die "Neither rish nor adb is available. Cannot install APKs."
fi

if [[ "$USE_RISH" == false && "$ADB_AVAILABLE" == true ]]; then
    info "Waiting for adb device …"
    adb wait-for-device 2>&1 || die "adb: no device found."
    SERIAL=$(adb get-serialno 2>/dev/null || echo "device")
    ok "adb connected: $SERIAL"
fi

# ─── Staging directory (needed by rish/pm) ────────────────────────────────────
# /data/local/tmp is world-readable — Termux home is not accessible to pm.
STAGE_DIR="/data/local/tmp/apk_install_$$"

if [[ "$USE_RISH" == true ]]; then
    info "Creating staging dir: $STAGE_DIR"
    STAGE_OUT=$(rish -c "mkdir -p '$STAGE_DIR' && chmod 777 '$STAGE_DIR' && echo staged_ok" 2>&1 || true)
    if ! echo "$STAGE_OUT" | grep -q "staged_ok"; then
        warn "rish could not create staging dir (${STAGE_OUT:-<no output>})."
        if [[ "$ADB_AVAILABLE" == true ]]; then
            adb shell "mkdir -p '$STAGE_DIR' && chmod 777 '$STAGE_DIR'" 2>&1 || true
        fi
    fi
fi

# ─── Install loop ─────────────────────────────────────────────────────────────
header "Installing"

OK_COUNT=0
FAIL_COUNT=0

for APK in "${APK_LIST[@]}"; do
    NAME="$(basename "$APK")"
    blank
    info "▶ $NAME"

    INSTALL_OK=false

    # ── rish path ─────────────────────────────────────────────────────────────
    if [[ "$USE_RISH" == true ]]; then
        STAGED="$STAGE_DIR/$NAME"

        # Copy to world-readable staging area and set permissions
        if cp "$APK" "$STAGED" 2>&1 && chmod 644 "$STAGED" 2>&1; then
            RISH_OUT=$(rish -c "pm install -r -t '$STAGED'" 2>&1 || true)
            echo "  $RISH_OUT"

            if echo "$RISH_OUT" | grep -qi "success"; then
                INSTALL_OK=true
            else
                warn "pm install did not report Success."
                if [[ "$ADB_AVAILABLE" == true ]]; then
                    warn "Trying adb fallback …"
                    ADB_OUT=$(adb install -r "$APK" 2>&1 || true)
                    echo "  $ADB_OUT"
                    echo "$ADB_OUT" | grep -qi "success" && INSTALL_OK=true
                fi
            fi
        else
            warn "Could not copy APK to staging dir — trying adb directly."
            if [[ "$ADB_AVAILABLE" == true ]]; then
                ADB_OUT=$(adb install -r "$APK" 2>&1 || true)
                echo "  $ADB_OUT"
                echo "$ADB_OUT" | grep -qi "success" && INSTALL_OK=true
            fi
        fi

        # Clean staged file
        rish -c "rm -f '$STAGED'" 2>/dev/null || true

    # ── adb-only path ─────────────────────────────────────────────────────────
    else
        ADB_OUT=$(adb install -r "$APK" 2>&1 || true)
        echo "  $ADB_OUT"
        echo "$ADB_OUT" | grep -qi "success" && INSTALL_OK=true
    fi

    if [[ "$INSTALL_OK" == true ]]; then
        ok "Installed: $NAME"
        OK_COUNT=$(( OK_COUNT + 1 ))
    else
        err "Failed:    $NAME"
        FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    fi
done

# ─── Cleanup staging dir ──────────────────────────────────────────────────────
if [[ "$USE_RISH" == true ]]; then
    rish -c "rm -rf '$STAGE_DIR'" 2>/dev/null || true
fi

# ─── Summary ──────────────────────────────────────────────────────────────────
header "Done"
echo -e "  Installed : ${BOLD}${GREEN}${OK_COUNT}${RESET}"
echo -e "  Failed    : ${BOLD}${RED}${FAIL_COUNT}${RESET}"
blank

[[ "$FAIL_COUNT" -gt 0 ]] && exit 1 || exit 0
