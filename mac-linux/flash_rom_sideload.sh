#!/usr/bin/env bash
#
# flash_axion_sideload.sh
# Sideload-flashes ROM rom.zip via OFOX recovery on Poco F5 (marble)
# Prompts for dirty flash vs clean flash before installing.
#
# Dirty flash : no wipes, just install rom.zip over existing setup
# Clean flash : fastboot -w (erase user data), then install
#
# Flow:
#   1. Verify rom.zip exists
#   2. Verify adb/fastboot available + device connected
#   3. Ask user: dirty or clean flash
#   4. [clean only] fastboot -w
#   5. fastboot reboot recovery
#   6. Wait for full adb (device state = recovery)
#   7. adb shell twrp sideload
#   8. Wait for sideload state
#   9. adb sideload rom.zip
#  10. Post-sideload settle delay
#  11. Ask user: reboot to system now? (default yes)
#
# Exits non-zero and stops immediately on any real failure.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------- Config ----------
ROM_ZIP="${SCRIPT_DIR}/rom.zip"
RECOVERY_WAIT_TIMEOUT=60      # seconds to wait for recovery state
SIDELOAD_WAIT_TIMEOUT=30      # seconds to wait for sideload state
POST_SIDELOAD_SETTLE=8        # seconds to wait after sideload completes (encrypted screen / minadbd handover)
POLL_INTERVAL=1               # seconds between state checks

# ---------- Colors ----------
if [ -t 1 ]; then
    C_RESET=$'\033[0m'
    C_DIM=$'\033[2m'
    C_BOLD=$'\033[1m'
    C_BLUE=$'\033[34m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_RED=$'\033[31m'
    C_CYAN=$'\033[36m'
else
    C_RESET=""; C_DIM=""; C_BOLD=""; C_BLUE=""; C_GREEN=""; C_YELLOW=""; C_RED=""; C_CYAN=""
fi

STEP_NUM=0
TOTAL_STEPS=6
START_TIME=$(date +%s)
FLASH_TYPE=""

# ---------- Helpers ----------
step() {
    STEP_NUM=$((STEP_NUM + 1))
    printf '\n%s[%d/%d]%s %s%s%s\n' "$C_BOLD$C_BLUE" "$STEP_NUM" "$TOTAL_STEPS" "$C_RESET" "$C_BOLD" "$1" "$C_RESET"
}

info() { printf '  %s→%s %s\n' "$C_CYAN" "$C_RESET" "$1"; }
ok()   { printf '  %s✓%s %s\n' "$C_GREEN" "$C_RESET" "$1"; }
warn() { printf '  %s!%s %s\n' "$C_YELLOW" "$C_RESET" "$1"; }
die()  { printf '\n  %s✗ ERROR:%s %s\n\n' "$C_RED$C_BOLD" "$C_RESET" "$1" >&2; exit 1; }

check_bin() {
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH. Install platform-tools."
}

get_adb_state() {
    "$ADB" devices 2>/dev/null | awk 'NR>1 && NF {print $2; exit}'
}

get_fastboot_state() {
    "$FASTBOOT" devices 2>/dev/null | awk 'NF {print "fastboot"; exit}'
}

wait_for_adb_state() {
    local target="$1"
    local timeout="$2"
    local waited=0
    local state=""
    while [ "$waited" -lt "$timeout" ]; do
        state="$(get_adb_state || true)"
        printf '\r  %s→%s waiting for '\''%s'\'' state... %s(%ds/%ds)%s ' \
            "$C_CYAN" "$C_RESET" "$target" "$C_DIM" "$waited" "$timeout" "$C_RESET"
        if [ "$state" = "$target" ]; then
            printf '\r  %s✓%s device reached '\''%s'\'' state.%s%s\n' \
                "$C_GREEN" "$C_RESET" "$target" "                     " "$C_RESET"
            return 0
        fi
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    printf '\n'
    die "timed out waiting for '$target' state (last seen: '${state:-none}')."
}

countdown() {
    local secs="$1"
    local label="$2"
    local i
    for ((i = secs; i > 0; i--)); do
        printf '\r  %s→%s %s %s(%ds)%s   ' "$C_CYAN" "$C_RESET" "$label" "$C_DIM" "$i" "$C_RESET"
        sleep 1
    done
    printf '\r  %s✓%s %s done.%s%s\n' "$C_GREEN" "$C_RESET" "$label" "                 " "$C_RESET"
}

elapsed() {
    local now
    now=$(date +%s)
    echo $((now - START_TIME))
}

# ---------- Bundled tools ----------
source "${SCRIPT_DIR}/common.sh" || die "common.sh missing or corrupted"
ADB="$(resolve_bundled_tool "platform-tools-${OS}" "adb")"
FASTBOOT="$(resolve_bundled_tool "platform-tools-${OS}" "fastboot")"

ask_flash_type() {
    printf '\n  %sHow do you want to flash %s?%s\n\n' "$C_BOLD" "$ROM_ZIP" "$C_RESET"
    printf '    %s1)%s Dirty flash  %s— install over existing setup, no wipes%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '    %s2)%s Clean flash  %s— fastboot -w (erase user data), then install%s\n' "$C_CYAN" "$C_RESET" "$C_DIM" "$C_RESET"
    printf '        %s(internal storage / your files are NOT touched either way)%s\n\n' "$C_DIM" "$C_RESET"

    while true; do
        printf '  Select [1/2]: '
        read -r choice
        case "$choice" in
            1) FLASH_TYPE="dirty"; break ;;
            2) FLASH_TYPE="clean"; break ;;
            *) warn "enter 1 or 2" ;;
        esac
    done
    ok "selected: ${FLASH_TYPE} flash"
}

ask_reboot_system() {
    printf '\n  Reboot to system now? %s[Y/n]%s: ' "$C_DIM" "$C_RESET"
    read -r choice
    case "$choice" in
        n|N|no|No) return 1 ;;
        *) return 0 ;;
    esac
}

# ---------- Banner ----------
printf '\n%s%s ROM Sideload %s\n' "$C_BOLD$C_BLUE" "▶" "$C_RESET"
printf '%srom: %s%s\n' "$C_DIM" "$ROM_ZIP" "$C_RESET"

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled adb ready"
ok "bundled fastboot ready"

if [ -f "$ROM_ZIP" ]; then
    ok "$ROM_ZIP found ($(du -h "$ROM_ZIP" | cut -f1))"
else
    die "'$ROM_ZIP' not found in current directory ($(pwd))."
fi

if [ -z "$(get_fastboot_state)" ] && [ -z "$(get_adb_state)" ]; then
    die "no device detected via adb or fastboot. Connect device and enable USB debugging / fastboot mode."
fi
ok "device detected"

ask_flash_type

# ---------- Step 2: Wipe (clean flash only) ----------
step "Wiping (${FLASH_TYPE} flash)"

if [ "$FLASH_TYPE" = "clean" ]; then
    info "running 'fastboot -w'..."
    "$FASTBOOT" -w || die "'fastboot -w' failed."
    ok "user data erased"
else
    info "dirty flash selected, skipping wipes"
fi

# ---------- Step 3: Reboot to recovery ----------
step "Rebooting to recovery"

if [ -n "$(get_fastboot_state)" ]; then
    info "device in fastboot, sending 'fastboot reboot recovery'"
    "$FASTBOOT" reboot recovery || die "'fastboot reboot recovery' failed."
else
    info "device already booted, sending 'adb reboot recovery'"
    "$ADB" reboot recovery || die "'adb reboot recovery' failed."
fi

wait_for_adb_state "recovery" "$RECOVERY_WAIT_TIMEOUT"

# ---------- Step 4: Trigger sideload mode ----------
step "Entering sideload mode"

# NOTE: this command's own exit code is unreliable. Triggering sideload
# kills the adbd session mid-command (device switches to minadbd), so
# adb shell often reports a broken pipe / non-zero exit even on success.
# We ignore that exit code and instead confirm the real result below.
info "sending 'adb shell twrp sideload'"
"$ADB" shell twrp sideload >/dev/null 2>&1 || true

wait_for_adb_state "sideload" "$SIDELOAD_WAIT_TIMEOUT"

# ---------- Step 5: Sideload the ROM ----------
step "Sideloading $ROM_ZIP"

if "$ADB" sideload "$ROM_ZIP"; then
    ok "transfer + install completed"
else
    die "adb sideload failed. Check cable/port, or that $ROM_ZIP is a valid signed zip."
fi

# ---------- Step 6: Wrapping up ----------
step "Wrapping up"

warn "screen may look frozen / show encrypted files right now — that's normal"
countdown "$POST_SIDELOAD_SETTLE" "waiting for minadbd -> adbd handover"

if ask_reboot_system; then
    info "rebooting to system..."
    if "$ADB" reboot; then
        ok "reboot command sent"
    else
        warn "'adb reboot' failed — reboot manually from the recovery menu"
    fi
else
    info "staying in recovery — reboot manually when ready"
fi

printf '\n%s%s ROM install complete (%s flash) — %ds total%s\n\n' \
    "$C_BOLD$C_GREEN" "✓" "$FLASH_TYPE" "$(elapsed)" "$C_RESET"