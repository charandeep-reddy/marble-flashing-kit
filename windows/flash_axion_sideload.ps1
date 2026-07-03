#Requires -Version 5.1
# flash_axion_sideload.ps1
# Sideload-flashes AxionOS axion.zip via OFOX recovery on Poco F5 (marble)
# Prompts for dirty flash vs clean flash before installing.
#
# Dirty flash : no wipes, just install axion.zip over existing setup
# Clean flash : fastboot -w (erase user data), then install
#
# Flow:
#   1. Verify axion.zip exists
#   2. Verify bundled adb/fastboot + device connected
#   3. Ask user: dirty or clean flash
#   4. [clean only] fastboot -w
#   5. fastboot reboot recovery
#   6. Wait for full adb (device state = recovery)
#   7. adb shell twrp sideload
#   8. Wait for sideload state
#   9. adb sideload axion.zip
#  10. Post-sideload settle delay
#  11. Ask user: reboot to system now? (default yes)
#
# Exits immediately on any real failure.

$ErrorActionPreference = "Stop"

# ---------- Config ----------
$AXION_ZIP = "axion.zip"
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
$FLASH_TYPE = ""

function step {
    param([string]$Message)
    $script:StepNum++
    Write-Host ""
    Write-Host "[$($script:StepNum)/6] $Message" -ForegroundColor Blue
}

function info {
    param([string]$Message)
    Write-Host "  -> $Message" -ForegroundColor Cyan
}

function ok {
    param([string]$Message)
    Write-Host "  [*] $Message" -ForegroundColor Green
}

function warn {
    param([string]$Message)
    Write-Host "  ! $Message" -ForegroundColor Yellow
}

function die {
    param([string]$Message)
    Write-Host ""
    Write-Host "  [X] ERROR: $Message" -ForegroundColor Red
    Write-Host ""
    exit 1
}

function Get-AdbState {
    $output = cmd /c "`"$ADB`" devices 2>&1"
    $lines = $output -split "`r?`n"
    for ($i = 1; $i -lt $lines.Count; $i++) {
        $parts = $lines[$i] -split "\s+"
        if ($parts.Count -ge 2) { return $parts[1] }
    }
    return $null
}

function Get-FastbootState {
    $output = cmd /c "`"$FASTBOOT`" devices 2>&1"
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
        Write-Host "`r  -> waiting for '$Target' state... ($waited/$Timeout) " -NoNewline -ForegroundColor Cyan
        if ($state -eq $Target) {
            Write-Host "`r  [*] device reached '$Target' state.                  " -ForegroundColor Green
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
        Write-Host "`r  -> $Label ($i)   " -NoNewline -ForegroundColor Cyan
        Start-Sleep -Seconds 1
    }
    Write-Host "`r  [*] $Label done.                 " -ForegroundColor Green
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

function Ask-FlashType {
    Write-Host ""
    Write-Host "  How do you want to flash $AXION_ZIP?" -ForegroundColor White
    Write-Host ""
    Write-Host "    1) Dirty flash  — install over existing setup, no wipes" -ForegroundColor Cyan
    Write-Host "    2) Clean flash  — fastboot -w (erase user data), then install" -ForegroundColor Cyan
    Write-Host "        (internal storage / your files are NOT touched either way)" -ForegroundColor Gray
    Write-Host ""

    while ($true) {
        Write-Host "  Select [1/2]: " -NoNewline
        $choice = Read-Host
        switch ($choice) {
            "1" { $script:FLASH_TYPE = "dirty"; break }
            "2" { $script:FLASH_TYPE = "clean"; break }
            default { warn "enter 1 or 2" }
        }
        if ($script:FLASH_TYPE) { break }
    }
    ok "selected: $($script:FLASH_TYPE) flash"
}

function Ask-RebootSystem {
    Write-Host ""
    Write-Host "  Reboot to system now? [Y/n]: " -NoNewline
    $choice = Read-Host
    return -not ($choice -match "^(n|no)$")
}

# ---------- Banner ----------
Write-Host ""
Write-Host ">> AxionOS Sideload" -ForegroundColor Blue
Write-Host "rom: $AXION_ZIP" -ForegroundColor Gray

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled adb ready"
ok "bundled fastboot ready"

if (Test-Path $AXION_ZIP -PathType Leaf) {
    ok "$AXION_ZIP found ($(Format-Size $AXION_ZIP))"
} else {
    die "'$AXION_ZIP' not found in current directory ($PWD)."
}

if (-not (Get-FastbootState) -and -not (Get-AdbState)) {
    die "no device detected via adb or fastboot. Connect device and enable USB debugging / fastboot mode."
}
ok "device detected"

Ask-FlashType

# ---------- Step 2: Wipe (clean flash only) ----------
step "Wiping ($FLASH_TYPE flash)"

if ($FLASH_TYPE -eq "clean") {
    info "running 'fastboot -w'..."
    & $FASTBOOT -w
    if ($LASTEXITCODE -ne 0) { die "'fastboot -w' failed." }
    ok "user data erased"
} else {
    info "dirty flash selected, skipping wipes"
}

# ---------- Step 3: Reboot to recovery ----------
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

# ---------- Step 4: Trigger sideload mode ----------
step "Entering sideload mode"

# NOTE: this command's own exit code is unreliable. Triggering sideload
# kills the adbd session mid-command, so adb shell often reports a broken
# pipe / non-zero exit even on success. We ignore that exit code and
# confirm the real result below.
info "sending 'adb shell twrp sideload'"
$null = cmd /c "`"$ADB`" shell twrp sideload 2>&1"

Wait-AdbState -Target "sideload" -Timeout $SIDELOAD_WAIT_TIMEOUT

# ---------- Step 5: Sideload the AxionOS ----------
step "Sideloading $AXION_ZIP"

& $ADB sideload $AXION_ZIP
if ($LASTEXITCODE -eq 0) {
    ok "transfer + install completed"
} else {
    die "adb sideload failed. Check cable/port, or that $AXION_ZIP is a valid signed zip."
}

# ---------- Step 6: Settle + reboot ----------
step "Wrapping up"

warn "screen may look frozen / show encrypted files right now — that's normal"
countdown -Secs $POST_SIDELOAD_SETTLE -Label "waiting for minadbd -> adbd handover"

if (Ask-RebootSystem) {
    info "rebooting to system..."
    & $ADB reboot
    if ($LASTEXITCODE -eq 0) {
        ok "reboot command sent"
    } else {
        warn "'adb reboot' failed — reboot manually from the recovery menu"
    }
} else {
    info "staying in recovery — reboot manually when ready"
}

Write-Host ""
Write-Host "[*] AxionOS install complete ($FLASH_TYPE flash) — $(elapsed)s total" -ForegroundColor Green
Write-Host ""
