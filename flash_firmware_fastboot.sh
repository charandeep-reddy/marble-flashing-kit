#!/usr/bin/env bash
#
# flash_firmware_fastboot.sh
# Fastboot-flashes firmware.zip (xiaomi-flashable-firmware-creator format)
# on Poco F5 (marble).
#
# Source: https://xiaomifirmwareupdater.com/
#
# ASSUMPTION: device is already in fastboot mode (bootloader). Firmware
# partitions can only be flashed there — NOT from fastbootd/recovery.
#
# Flow:
#   1. Pre-flight: fastboot/unzip in PATH, firmware.zip present, device in fastboot
#   2. Extract firmware.zip -> firmware/
#   3. Flash each partition to ${partition}_ab from firmware/firmware-update/
#
# Exits non-zero and stops immediately on any real failure.

set -uo pipefail

# ---------- Config ----------
FIRMWARE_ZIP="firmware.zip"
FIRMWARE_DIR="firmware"
UPDATE_DIR="${FIRMWARE_DIR}/firmware-update"

partitions=(
    "abl" "aop" "aop_config" "bluetooth" "cpucp" "devcfg" "dsp"
    "featenabler" "hyp" "imagefv" "keymaster" "modem" "qupfw"
    "shrm" "tz" "uefi" "uefisecapp" "xbl" "xbl_config" "xbl_ramdump"
)

TOTAL_PARTITIONS=${#partitions[@]}

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
TOTAL_STEPS=3
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
    local bin="$1"
    local hint="${2:-Install platform-tools.}"
    command -v "$bin" >/dev/null 2>&1 || die "'$bin' not found in PATH. $hint"
}

get_fastboot_state() {
    fastboot devices 2>/dev/null | awk 'NF {print "fastboot"; exit}'
}

elapsed() {
    local now
    now=$(date +%s)
    echo $((now - START_TIME))
}

# ---------- Banner ----------
printf '\n%s%s Firmware Fastboot Flash %s\n' "$C_BOLD$C_BLUE" "▶" "$C_RESET"
printf '%sdevice: marble (Poco F5) | firmware: %s%s\n' "$C_DIM" "$FIRMWARE_ZIP" "$C_RESET"

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

check_bin fastboot
ok "fastboot found"
check_bin unzip "Install unzip (e.g. brew install unzip / apt install unzip)."
ok "unzip found"

if [ -f "$FIRMWARE_ZIP" ]; then
    ok "$FIRMWARE_ZIP found ($(du -h "$FIRMWARE_ZIP" | cut -f1))"
else
    die "'$FIRMWARE_ZIP' not found in current directory ($(pwd))."
fi

if [ -z "$(get_fastboot_state)" ]; then
    die "no device detected in fastboot mode. Boot to bootloader first (not recovery/fastbootd)."
fi
ok "device detected in fastboot mode"

# ---------- Step 2: Extract firmware ----------
step "Extracting $FIRMWARE_ZIP"

info "extracting to ${FIRMWARE_DIR}/"
if unzip -o "$FIRMWARE_ZIP" -d "$FIRMWARE_DIR"; then
    ok "extraction complete"
else
    die "failed to extract '$FIRMWARE_ZIP'."
fi

if [ ! -d "$UPDATE_DIR" ]; then
    die "expected '$UPDATE_DIR' not found after extraction — is this a valid firmware zip?"
fi

# ---------- Step 3: Flash partitions ----------
step "Flashing firmware partitions"

flashed=0
for partition in "${partitions[@]}"; do
    flashed=$((flashed + 1))
    img="${UPDATE_DIR}/${partition}.img"

    if [ ! -f "$img" ]; then
        die "missing image for '$partition' (expected '$img')."
    fi

    printf '  %s[%d/%d]%s Flashing %s... ' \
        "$C_BOLD$C_BLUE" "$flashed" "$TOTAL_PARTITIONS" "$C_RESET" "$partition"

    if fastboot flash "${partition}_ab" "$img"; then
        printf '%s✓%s\n' "$C_GREEN" "$C_RESET"
    else
        printf '%s✗%s\n' "$C_RED" "$C_RESET"
        die "flashing '$partition' to '${partition}_ab' failed."
    fi
done

printf '\n%s%s Firmware flash complete — %d/%d partitions flashed in %ds%s\n\n' \
    "$C_BOLD$C_GREEN" "✓" "$TOTAL_PARTITIONS" "$TOTAL_PARTITIONS" "$(elapsed)" "$C_RESET"
exit 0
