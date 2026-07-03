#Requires -Version 5.1
# flash_firmware_fastboot.ps1
# Fastboot-flashes firmware.zip (xiaomi-flashable-firmware-creator format)
# on Poco F5 (marble).
#
# Source: https://xiaomifirmwareupdater.com/
#
# ASSUMPTION: device is already in fastboot mode (bootloader). Firmware
# partitions can only be flashed there — NOT from fastbootd/recovery.
#
# Flow:
#   1. Pre-flight: bundled fastboot, firmware.zip present, device in fastboot
#   2. Extract firmware.zip -> firmware/
#   3. Flash each partition to ${partition}_ab from firmware/firmware-update/
#
# Exits immediately on any real failure.

$ErrorActionPreference = "Stop"

# ---------- Config ----------
$FIRMWARE_ZIP = "firmware.zip"
$FIRMWARE_DIR = "firmware"
$UPDATE_DIR = "$FIRMWARE_DIR\firmware-update"

$partitions = @(
    "abl", "aop", "aop_config", "bluetooth", "cpucp", "devcfg", "dsp",
    "featenabler", "hyp", "imagefv", "keymaster", "modem", "qupfw",
    "shrm", "tz", "uefi", "uefisecapp", "xbl", "xbl_config", "xbl_ramdump"
)

$TOTAL_PARTITIONS = $partitions.Count

# ---------- Bundled tools ----------
. "$PSScriptRoot\common.ps1"
$FASTBOOT = Resolve-BundledTool -SubDir "platform-tools-windows" -FileName "fastboot.exe"

# ---------- Helpers ----------
$script:StepNum = 0
$script:StartTime = Get-Date

function step {
    param([string]$Message)
    $script:StepNum++
    Write-Host ""
    Write-Host "[$($script:StepNum)/3] $Message" -ForegroundColor Blue
}

function info {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor Cyan
}

function ok {
    param([string]$Message)
    Write-Host "  ✓ $Message" -ForegroundColor Green
}

function warn {
    param([string]$Message)
    Write-Host "  ! $Message" -ForegroundColor Yellow
}

function die {
    param([string]$Message)
    Write-Host ""
    Write-Host "  ✗ ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

function Get-FastbootState {
    $output = & $FASTBOOT devices 2>&1
    if ($output -match "\S+\s+fastboot") { return "fastboot" }
    return $null
}

function elapsed {
    return [int]((Get-Date) - $script:StartTime).TotalSeconds
}

function Format-Size {
    param([string]$Path)
    $bytes = (Get-Item $Path).Length
    if ($bytes -ge 1GB) { return "{0:F1}G" -f ($bytes / 1GB) }
    if ($bytes -ge 1MB) { return "{0:F1}M" -f ($bytes / 1MB) }
    if ($bytes -ge 1KB) { return "{0:F1}K" -f ($bytes / 1KB) }
    return "$bytes B"
}

# ---------- Banner ----------
Write-Host ""
Write-Host "▶ Firmware Fastboot Flash" -ForegroundColor Blue
Write-Host "device: marble (Poco F5) | firmware: $FIRMWARE_ZIP" -ForegroundColor Gray

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled fastboot ready"

if (Test-Path $FIRMWARE_ZIP -PathType Leaf) {
    ok "$FIRMWARE_ZIP found ($(Format-Size $FIRMWARE_ZIP))"
} else {
    die "'$FIRMWARE_ZIP' not found in current directory ($PWD)."
}

if (-not (Get-FastbootState)) {
    die "no device detected in fastboot mode. Boot to bootloader first (not recovery/fastbootd)."
}
ok "device detected in fastboot mode"

# ---------- Step 2: Extract firmware ----------
step "Extracting $FIRMWARE_ZIP"

info "extracting to ${FIRMWARE_DIR}/"
try {
    Expand-Archive -Path $FIRMWARE_ZIP -DestinationPath $FIRMWARE_DIR -Force
    ok "extraction complete"
} catch {
    die "failed to extract '$FIRMWARE_ZIP'."
}

if (-not (Test-Path $UPDATE_DIR -PathType Container)) {
    die "expected '$UPDATE_DIR' not found after extraction — is this a valid firmware zip?"
}

# ---------- Step 3: Flash partitions ----------
step "Flashing firmware partitions"

$flashed = 0
foreach ($partition in $partitions) {
    $flashed++
    $img = "$UPDATE_DIR\$partition.img"

    if (-not (Test-Path $img -PathType Leaf)) {
        die "missing image for '$partition' (expected '$img')."
    }

    Write-Host "  [$flashed/$TOTAL_PARTITIONS] Flashing $partition... " -NoNewline -ForegroundColor Blue

    & $FASTBOOT flash "${partition}_ab" $img
    if ($LASTEXITCODE -eq 0) {
        Write-Host "✓" -ForegroundColor Green
    } else {
        Write-Host "✗" -ForegroundColor Red
        die "flashing '$partition' to '${partition}_ab' failed."
    }
}

Write-Host ""
Write-Host "✓ Firmware flash complete — $TOTAL_PARTITIONS/$TOTAL_PARTITIONS partitions flashed in $(elapsed)s" -ForegroundColor Green
Write-Host ""
