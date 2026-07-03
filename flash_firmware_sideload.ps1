#Requires -Version 5.1
# flash_firmware_sideload.ps1
# Sideload-flashes AxionOS firmware.zip via OFOX recovery on Poco F5 (marble)
#
# Flow:
#   1. Verify firmware.zip exists
#   2. Verify bundled adb/fastboot + device connected
#   3. fastboot reboot recovery
#   4. Wait for full adb (device state = recovery)
#   5. adb shell twrp sideload
#   6. Wait for sideload state
#   7. adb sideload firmware.zip
#   8. Post-sideload settle delay
#   9. adb reboot bootloader
#
# Exits immediately on any real failure.

$ErrorActionPreference = "Stop"

# ---------- Config ----------
$FIRMWARE_ZIP = "firmware.zip"
$RECOVERY_WAIT_TIMEOUT = 60
$SIDELOAD_WAIT_TIMEOUT = 30
$POST_SIDELOAD_SETTLE = 8
$POLL_INTERVAL = 1

# ---------- Bundled tools ----------
. "$PSScriptRoot\common.ps1"
$ADB = Resolve-BundledTool -SubDir "platform-tools-windows" -FileName "adb.exe"
$FASTBOOT = Resolve-BundledTool -SubDir "platform-tools-windows" -FileName "fastboot.exe"

# ---------- Helpers ----------
$script:StepNum = 0
$script:StartTime = Get-Date

function step {
    param([string]$Message)
    $script:StepNum++
    Write-Host ""
    Write-Host "[$($script:StepNum)/6] $Message" -ForegroundColor Blue
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

function Get-AdbState {
    $output = & $ADB devices 2>&1
    $lines = $output -split "`r?`n"
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $parts = $lines[$i] -split "\s+"
        if ($parts.Count -ge 2) { return $parts[1] }
    }
    return $null
}

function Get-FastbootState {
    $output = & $FASTBOOT devices 2>&1
    if ($output -match "\S+\s+fastboot") { return "fastboot" }
    return $null
}

function Wait-AdbState {
    param(
        [string]$Target,
        [int]$Timeout
    )
    $waited = 0
    $state = $null
    while ($waited -lt $Timeout) {
        $state = Get-AdbState
        Write-Host "`r  → waiting for '$Target' state... ($waited/$Timeout) " -NoNewline -ForegroundColor Cyan
        if ($state -eq $Target) {
            Write-Host "`r  ✓ device reached '$Target' state.                  " -ForegroundColor Green
            return
        }
        Start-Sleep -Seconds $POLL_INTERVAL
        $waited += $POLL_INTERVAL
    }
    Write-Host ""
    die "timed out waiting for '$Target' state (last seen: '$state')."
}

function countdown {
    param(
        [int]$Secs,
        [string]$Label
    )
    for ($i = $Secs; $i -gt 0; $i--) {
        Write-Host "`r  → $Label ($i)   " -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  ✓ $Label done.                 " -ForegroundColor Green
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
Write-Host "▶ AxionOS Firmware Sideload" -ForegroundColor Blue
Write-Host "firmware: $FIRMWARE_ZIP" -ForegroundColor Gray

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled adb ready"
ok "bundled fastboot ready"

if (Test-Path $FIRMWARE_ZIP -PathType Leaf) {
    ok "$FIRMWARE_ZIP found ($(Format-Size $FIRMWARE_ZIP))"
} else {
    die "'$FIRMWARE_ZIP' not found in current directory ($PWD)."
}

if (-not (Get-FastbootState) -and -not (Get-AdbState)) {
    die "no device detected via adb or fastboot. Connect device and enable USB debugging / fastboot mode."
}
ok "device detected"

# ---------- Step 2: Reboot to recovery ----------
step "Rebooting to recovery"

if (Get-FastbootState) {
    info "device in fastboot, sending 'fastboot reboot recovery'"
    & $FASTBOOT reboot recovery
    if ($LASTEXITCODE -ne 0) { die "'fastboot reboot recovery' failed." }
} else {
    info "device already booted, sending 'adb reboot recovery'"
    & $ADB reboot recovery
    if ($LASTEXITCODE -ne 0) { die "'adb reboot recovery' failed." }
}

Wait-AdbState -Target "recovery" -Timeout $RECOVERY_WAIT_TIMEOUT

# ---------- Step 3: Trigger sideload mode ----------
step "Entering sideload mode"

# NOTE: this command's own exit code is unreliable. Triggering sideload
# kills the adbd session mid-command, so adb shell often reports a broken
# pipe / non-zero exit even on success. We ignore that exit code and
# confirm the real result below.
info "sending 'adb shell twrp sideload'"
$null = & $ADB shell twrp sideload 2>&1

Wait-AdbState -Target "sideload" -Timeout $SIDELOAD_WAIT_TIMEOUT

# ---------- Step 4: Sideload the zip ----------
step "Sideloading $FIRMWARE_ZIP"

& $ADB sideload $FIRMWARE_ZIP
if ($LASTEXITCODE -eq 0) {
    ok "transfer + install completed"
} else {
    die "adb sideload failed. Check cable/port, or that $FIRMWARE_ZIP is a valid signed zip."
}

# ---------- Step 5: Settle delay ----------
step "Letting recovery settle"

warn "screen may look frozen / show encrypted files right now — that's normal"
countdown -Secs $POST_SIDELOAD_SETTLE -Label "waiting for minadbd -> adbd handover"

# ---------- Step 6: Reboot to bootloader ----------
step "Rebooting to bootloader"

& $ADB reboot bootloader
if ($LASTEXITCODE -eq 0) {
    info "reboot command sent"
} else {
    die "'adb reboot bootloader' failed. Device may still be mid-handover — rerun manually: adb reboot bootloader"
}

$waited = 0
while ($waited -lt $RECOVERY_WAIT_TIMEOUT) {
    Write-Host "`r  → waiting for fastboot... ($waited/$RECOVERY_WAIT_TIMEOUT) " -NoNewline -ForegroundColor Cyan
    if (Get-FastbootState) {
        Write-Host "`r  ✓ device confirmed in fastboot mode.                  " -ForegroundColor Green
        Write-Host ""
        Write-Host "✓ Flash complete — $(elapsed)s total" -ForegroundColor Green
        Write-Host ""
        exit 0
    }
    Start-Sleep -Seconds $POLL_INTERVAL
    $waited += $POLL_INTERVAL
}

Write-Host ""
die "sideload completed but device did not appear in fastboot within ${RECOVERY_WAIT_TIMEOUT}s. Check device screen manually."
