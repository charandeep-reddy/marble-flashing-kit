#!/usr/bin/env bash
#
# flash_axion_fastboot.sh
# Flashes AxionOS on Poco F5 (marble) fully via fastboot/fastbootd — no sideload.
# Requires device already sitting in fastboot (bootloader) mode.
#
# Dirty flash : no wipes, straight install
# Clean flash : fastboot -w (erase user data) after extraction, just before first flash
#
# Flow:
#   1. Pre-flight checks (deps, device in fastboot mode)
#   2. Bootloader unlock check
#   3. Extract axion.zip -> axion/images/ (skipped if already present + valid)
#   4. Ask user: dirty or clean flash
#   5. [clean only] fastboot -w
#   6. Flash static partitions (boot, vendor_boot, dtbo, vbmeta, vbmeta_system)
#      + recovery (root-folder OFOX if found, otherwise payload's own)
#   7. fastboot reboot fastboot -> wait for fastbootd
#   8. Flash logical partitions (system, system_ext, product, vendor, odm, vendor_dlkm)
#   9. Final fastboot reboot
#
# Exits non-zero and stops immediately on any real failure.

set -uo pipefail

# ---------- Config ----------
AXION_ZIP="axion.zip"
RECOVERY_IMG="recovery.img"          # root-folder OFOX build (optional) — fallback is axion/images/recovery.img from payload
AXION_DIR="axion"
IMAGES_DIR="${AXION_DIR}/images"
FASTBOOTD_WAIT_TIMEOUT=60
POLL_INTERVAL=1

# Partitions flashed while still in bootloader (plain fastboot)
STATIC_PARTITIONS=(boot vendor_boot dtbo vbmeta vbmeta_system)

# Partitions flashed after entering fastbootd (logical, live in super)
LOGICAL_PARTITIONS=(system system_ext product vendor odm vendor_dlkm)

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
TOTAL_STEPS=9
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
    command -v "$1" >/dev/null 2>&1 || die "'$1' not found in PATH.$([ -n "${2:-}" ] && printf ' %s' "$2")"
}

get_fastboot_state() {
    "$FASTBOOT" devices 2>/dev/null | awk 'NF {print "fastboot"; exit}'
}

# fastboot getvar writes to stderr; parse "name: value" out of it
get_fastboot_var() {
    local var="$1"
    "$FASTBOOT" getvar "$var" 2>&1 | awk -F': ' -v v="$var" '$0 ~ "^"v": " {print $2; exit}'
}

wait_for_fastbootd() {
    local timeout="$1"
    local waited=0
    local state=""
    while [ "$waited" -lt "$timeout" ]; do
        printf '\r  %s→%s waiting for fastbootd... %s(%ds/%ds)%s ' \
            "$C_CYAN" "$C_RESET" "$C_DIM" "$waited" "$timeout" "$C_RESET"
        if [ -n "$(get_fastboot_state)" ]; then
            state="$(get_fastboot_var is-userspace)"
            if [ "$state" = "yes" ]; then
                printf '\r  %s✓%s fastbootd is up.%s%s\n' \
                    "$C_GREEN" "$C_RESET" "                     " "$C_RESET"
                return 0
            fi
        fi
        sleep "$POLL_INTERVAL"
        waited=$((waited + POLL_INTERVAL))
    done
    printf '\n'
    die "timed out waiting for fastbootd (device never reported is-userspace: yes)."
}

ask_flash_type() {
    printf '\n  %sHow do you want to flash %s?%s\n\n' "$C_BOLD" "$AXION_ZIP" "$C_RESET"
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

ask_yes_no() {
    local prompt="$1"
    printf '\n  %s %s[Y/n]%s: ' "$prompt" "$C_DIM" "$C_RESET"
    read -r choice
    case "$choice" in
        n|N|no|No) return 1 ;;
        *) return 0 ;;
    esac
}

elapsed() {
    local now
    now=$(date +%s)
    echo $((now - START_TIME))
}

# ---------- Bundled tools ----------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common.sh" || die "common.sh missing or corrupted"
FASTBOOT="$(resolve_bundled_tool "platform-tools-${OS}" "fastboot")"
PAYLOAD_DUMPER="$(resolve_bundled_tool "payload-dumper-go-${OS}" "payload-dumper-go")"

# ---------- Banner ----------
printf '\n%s%s AxionOS Fastboot Flash %s\n' "$C_BOLD$C_BLUE" "▶" "$C_RESET"
printf '%srom: %s   recovery: %s (or fallback from payload)%s\n' "$C_DIM" "$AXION_ZIP" "$RECOVERY_IMG" "$C_RESET"

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled fastboot ready"
check_bin unzip
ok "unzip found"
ok "bundled payload-dumper-go ready"

[ -n "$(get_fastboot_state)" ] || die "no device detected in fastboot mode. Boot into fastboot and connect via USB, then rerun."
ok "device detected in fastboot"

# ---------- Step 2: Bootloader unlock check ----------
step "Checking bootloader"

UNLOCKED="$(get_fastboot_var unlocked)"
if [ "$UNLOCKED" = "yes" ]; then
    ok "bootloader is unlocked"
else
    die "bootloader is not unlocked (reported: '${UNLOCKED:-unknown}'). Unlock it before flashing."
fi

# ---------- Step 3: Extract axion.zip ----------
step "Preparing images"

if [ -d "$IMAGES_DIR" ] && [ -n "$(ls -A "$IMAGES_DIR" 2>/dev/null)" ]; then
    ok "'$IMAGES_DIR' already exists, skipping extraction"
    # Sanity-check the cache actually has what we need before trusting it
    missing=()
    for p in "${STATIC_PARTITIONS[@]}" "${LOGICAL_PARTITIONS[@]}"; do
        [ -f "${IMAGES_DIR}/${p}.img" ] || missing+=("$p")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "'$IMAGES_DIR' exists but is missing images for: ${missing[*]}. Delete '$AXION_DIR' and rerun to re-extract."
    fi
    ok "cached images verified complete"
else
    ask_yes_no "Make sure '$AXION_ZIP' is in this folder (recovery.img is optional — falls back to payload's if missing). Ready?" \
        || die "place '$AXION_ZIP' in this folder, then rerun."

    [ -f "$AXION_ZIP" ] || die "'$AXION_ZIP' not found in current directory ($(pwd))."
    ok "$AXION_ZIP found"

    info "unzipping $AXION_ZIP -> $AXION_DIR/ ..."
    unzip -o -q "$AXION_ZIP" -d "$AXION_DIR" || die "failed to unzip $AXION_ZIP."
    ok "extracted"

    [ -f "${AXION_DIR}/payload.bin" ] || die "'payload.bin' not found inside $AXION_ZIP."
    ok "payload.bin found"

    info "running payload-dumper-go (this can take a few minutes)..."
    "$PAYLOAD_DUMPER" -o "$IMAGES_DIR" "${AXION_DIR}/payload.bin" \
        || die "payload-dumper-go failed to extract payload.bin."
    ok "images extracted to $IMAGES_DIR"

    missing=()
    for p in "${STATIC_PARTITIONS[@]}" "${LOGICAL_PARTITIONS[@]}"; do
        [ -f "${IMAGES_DIR}/${p}.img" ] || missing+=("$p")
    done
    if [ "${#missing[@]}" -gt 0 ]; then
        die "extraction finished but missing images for: ${missing[*]}."
    fi
    ok "all required images present"
fi

# ---------- Step 4: Ask flash type ----------
step "Choosing flash type"
ask_flash_type

# ---------- Step 5: Wipe (clean flash only, after extraction) ----------
step "Wiping (${FLASH_TYPE} flash)"

if [ "$FLASH_TYPE" = "clean" ]; then
    [ -n "$(get_fastboot_state)" ] || die "device not in fastboot mode. Boot into fastboot first, then rerun."
    info "running 'fastboot -w'..."
    "$FASTBOOT" -w || die "'fastboot -w' failed."
    ok "user data erased"
else
    info "dirty flash selected, skipping wipe"
fi

# ---------- Step 6: Flash static partitions + recovery ----------
step "Flashing static partitions (bootloader)"

for partition in "${STATIC_PARTITIONS[@]}"; do
    info "flashing ${partition}..."
    if "$FASTBOOT" flash "$partition" "${IMAGES_DIR}/${partition}.img"; then
        ok "${partition} flashed"
    else
        die "failed to flash '${partition}'."
    fi
done

if [ -f "$RECOVERY_IMG" ]; then
    info "flashing recovery (custom OFOX from root folder)..."
    "$FASTBOOT" flash recovery "$RECOVERY_IMG" || die "failed to flash recovery."
    ok "recovery flashed (custom OFOX)"
elif [ -f "${IMAGES_DIR}/recovery.img" ]; then
    info "flashing recovery (stock, from payload — no custom recovery.img found in root)..."
    "$FASTBOOT" flash recovery "${IMAGES_DIR}/recovery.img" || die "failed to flash recovery."
    ok "recovery flashed (from payload)"
else
    die "no recovery image available — '$RECOVERY_IMG' not found in root and payload didn't produce '${IMAGES_DIR}/recovery.img'. Place a custom recovery.img in the root folder and rerun."
fi

# ---------- Step 7: Enter fastbootd ----------
step "Entering fastbootd"

info "sending 'fastboot reboot fastboot'..."
"$FASTBOOT" reboot fastboot || die "'fastboot reboot fastboot' failed."
wait_for_fastbootd "$FASTBOOTD_WAIT_TIMEOUT"

# ---------- Step 8: Flash logical partitions ----------
step "Flashing logical partitions (fastbootd)"

for partition in "${LOGICAL_PARTITIONS[@]}"; do
    info "flashing ${partition}..."
    if "$FASTBOOT" flash "$partition" "${IMAGES_DIR}/${partition}.img"; then
        ok "${partition} flashed"
    else
        die "failed to flash '${partition}'. If this says 'not enough space', your previous ROM's partition layout likely differs from AxionOS's — you'll need to manually delete-logical-partition '${partition}' (both _a and _b slots) and retry."
    fi
done

# ---------- Step 9: Final reboot ----------
step "Finishing up"

info "rebooting..."
if "$FASTBOOT" reboot; then
    ok "reboot command sent"
else
    warn "'fastboot reboot' failed — reboot manually."
fi

printf '\n%s%s AxionOS flash complete (%s flash) — %ds total%s\n\n' \
    "$C_BOLD$C_GREEN" "✓" "$FLASH_TYPE" "$(elapsed)" "$C_RESET"