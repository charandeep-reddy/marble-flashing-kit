#!/usr/bin/env bash
#
# flash_firmware_sideload.sh
# Sideload-flashes AxionOS firmware.zip via OFOX recovery on Poco F5 (marble)
#
# Flow:
#   1. Verify firmware.zip exists
#   2. Verify adb/fastboot available + device connected
#   3. fastboot reboot recovery
#   4. Wait for full adb (device state = recovery)
#   5. adb shell twrp sideload
#   6. Wait for sideload state
#   7. adb sideload firmware.zip
#   8. Post-sideload settle delay (minadbd -> adbd handover is flaky)
#   9. adb reboot bootloader
#
# Exits non-zero and stops immediately on any real failure.

set -uo pipefail

# ---------- Config ----------
FIRMWARE_ZIP="firmware.zip"
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

# Waits for an adb state, printing a single self-updating progress line
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
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh" || die "common.sh missing or corrupted"
ADB="$(resolve_bundled_tool "platform-tools-${OS}" "adb")"
FASTBOOT="$(resolve_bundled_tool "platform-tools-${OS}" "fastboot")"

# ---------- Banner ----------
printf '\n%s%s AxionOS Sideload Flash %s\n' "$C_BOLD$C_BLUE" "▶" "$C_RESET"
printf '%sfirmware: %s%s\n' "$C_DIM" "$FIRMWARE_ZIP" "$C_RESET"

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled adb ready"
ok "bundled fastboot ready"

if [ -f "$FIRMWARE_ZIP" ]; then
    ok "$FIRMWARE_ZIP found ($(du -h "$FIRMWARE_ZIP" | cut -f1))"
else
    die "'$FIRMWARE_ZIP' not found in current directory ($(pwd))."
fi

if [ -z "$(get_fastboot_state)" ] && [ -z "$(get_adb_state)" ]; then
    die "no device detected via adb or fastboot. Connect device and enable USB debugging / fastboot mode."
fi
ok "device detected"

# ---------- Step 2: Reboot to recovery ----------
step "Rebooting to recovery"

if [ -n "$(get_fastboot_state)" ]; then
    info "device in fastboot, sending 'fastboot reboot recovery'"
    "$FASTBOOT" reboot recovery || die "'fastboot reboot recovery' failed."
else
    info "device already booted, sending 'adb reboot recovery'"
    "$ADB" reboot recovery || die "'adb reboot recovery' failed."
fi

wait_for_adb_state "recovery" "$RECOVERY_WAIT_TIMEOUT"

# ---------- Step 3: Trigger sideload mode ----------
step "Entering sideload mode"

# NOTE: this command's own exit code is unreliable. Triggering sideload
# kills the adbd session mid-command (device switches to minadbd), so
# adb shell often reports a broken pipe / non-zero exit even on success.
# We ignore that exit code and instead confirm the real result below.
info "sending 'adb shell twrp sideload'"
"$ADB" shell twrp sideload >/dev/null 2>&1 || true

wait_for_adb_state "sideload" "$SIDELOAD_WAIT_TIMEOUT"

# ---------- Step 4: Sideload the zip ----------
step "Sideloading $FIRMWARE_ZIP"

if "$ADB" sideload "$FIRMWARE_ZIP"; then
    ok "transfer + install completed"
else
    die "adb sideload failed. Check cable/port, or that $FIRMWARE_ZIP is a valid signed zip."
fi

# ---------- Step 5: Settle delay ----------
step "Letting recovery settle"

warn "screen may look frozen / show encrypted files right now — that's normal"
countdown "$POST_SIDELOAD_SETTLE" "waiting for minadbd -> adbd handover"

# ---------- Step 6: Reboot to bootloader ----------
step "Rebooting to bootloader"

if "$ADB" reboot bootloader; then
    info "reboot command sent"
else
    die "'adb reboot bootloader' failed. Device may still be mid-handover — rerun manually: adb reboot bootloader"
fi

waited=0
while [ "$waited" -lt "$RECOVERY_WAIT_TIMEOUT" ]; do
    printf '\r  %s→%s waiting for fastboot... %s(%ds/%ds)%s ' \
        "$C_CYAN" "$C_RESET" "$C_DIM" "$waited" "$RECOVERY_WAIT_TIMEOUT" "$C_RESET"
    if [ -n "$(get_fastboot_state)" ]; then
        printf '\r  %s✓%s device confirmed in fastboot mode.%s%s\n' \
            "$C_GREEN" "$C_RESET" "                     " "$C_RESET"
        printf '\n%s%s Flash complete — %ds total%s\n\n' "$C_BOLD$C_GREEN" "✓" "$(elapsed)" "$C_RESET"
        exit 0
    fi
    sleep "$POLL_INTERVAL"
    waited=$((waited + POLL_INTERVAL))
done

printf '\n'
die "sideload completed but device did not appear in fastboot within ${RECOVERY_WAIT_TIMEOUT}s. Check device screen manually."