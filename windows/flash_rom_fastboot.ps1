#Requires -Version 5.1
# flash_axion_fastboot.ps1
# Flashes ROM on Poco F5 (marble) fully via fastboot/fastbootd — no sideload.
# Requires device already sitting in fastboot (bootloader) mode.
#
# Dirty flash : no wipes, straight install
# Clean flash : fastboot -w (erase user data) after extraction, just before first flash
#
# Flow:
#   1. Pre-flight checks (deps, device in fastboot mode)
#   2. Bootloader unlock check
#   3. Extract rom.zip -> axion/images/ (skipped if already present + valid)
#   4. Ask user: dirty or clean flash
#   5. [clean only] fastboot -w
#   6. Flash static partitions (boot, vendor_boot, dtbo, vbmeta, vbmeta_system)
#      + recovery (root-folder OFOX if found, otherwise payload's own)
#   7. fastboot reboot fastboot -> wait for fastbootd
#   8. Flash logical partitions (system, system_ext, product, vendor, odm, vendor_dlkm)
#   9. Final fastboot reboot
#
# Exits immediately on any real failure.

$ErrorActionPreference = "Stop"

# ---------- Config ----------
$ROM_ZIP = "$PSScriptRoot\rom.zip"
$RECOVERY_IMG = "$PSScriptRoot\recovery.img"          # root-folder OFOX build (optional) — fallback is axion/images/recovery.img from payload
$ROM_DIR = "$PSScriptRoot\axion"
$IMAGES_DIR = "$ROM_DIR\images"
$FASTBOOTD_WAIT_TIMEOUT = 60
$POLL_INTERVAL = 1

# Partitions flashed while still in bootloader (plain fastboot)
$STATIC_PARTITIONS = @("boot", "vendor_boot", "dtbo", "vbmeta", "vbmeta_system")

# Partitions flashed after entering fastbootd (logical, live in super)
$LOGICAL_PARTITIONS = @("system", "system_ext", "product", "vendor", "odm", "vendor_dlkm")

# ---------- Bundled tools ----------
. "$PSScriptRoot\common.ps1"
$FASTBOOT = Resolve-BundledTool -SubDir "platform-tools-windows" -FileName "fastboot.exe"
$PAYLOAD_DUMPER = Resolve-BundledTool -SubDir "payload-dumper-go-windows" -FileName "payload-dumper-go.exe"

# ---------- Helpers ----------
$script:StepNum = 0
$script:StartTime = Get-Date
$FLASH_TYPE = ""

function step {
    param([string]$Message)
    $script:StepNum++
    Write-Host ""
    Write-Host "[$($script:StepNum)/9] $Message" -ForegroundColor Blue
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

function Get-FastbootState {
    $output = cmd /c "`"$FASTBOOT`" devices 2>&1"
    if ($output -match "\S+\s+fastboot") { return "fastboot" }
    return $null
}

# fastboot getvar writes to stderr; parse "name: value" out of it
function Get-FastbootVar {
    param([string]$Var)
    $output = cmd /c "`"$FASTBOOT`" getvar $Var 2>&1"
    foreach ($line in $output) {
        if ($line -match "^$Var`: (.+)") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Wait-Fastbootd {
    param([int]$Timeout)
    $waited = 0
    while ($waited -lt $Timeout) {
        Write-Host "`r  -> waiting for fastbootd... ($waited/$Timeout) " -NoNewline -ForegroundColor Cyan
        if (Get-FastbootState) {
            $state = Get-FastbootVar -Var "is-userspace"
            if ($state -eq "yes") {
                Write-Host "`r  [*] fastbootd is up.                  " -ForegroundColor Green
                return
            }
        }
        Start-Sleep -Seconds $POLL_INTERVAL
        $waited += $POLL_INTERVAL
    }
    Write-Host ""
    die "timed out waiting for fastbootd (device never reported is-userspace: yes)."
}

function Ask-FlashType {
    Write-Host ""
    Write-Host "  How do you want to flash $ROM_ZIP?" -ForegroundColor White
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

function Ask-YesNo {
    param([string]$Prompt)
    Write-Host ""
    Write-Host "  $Prompt [Y/n]: " -NoNewline
    $choice = Read-Host
    return -not ($choice -match "^(n|no)$")
}

function elapsed {
    return [int]((Get-Date) - $script:StartTime).TotalSeconds
}

# ---------- Banner ----------
Write-Host ""
Write-Host ">> ROM Fastboot Flash" -ForegroundColor Blue
Write-Host "rom: $ROM_ZIP   recovery: $RECOVERY_IMG (or fallback from payload)" -ForegroundColor Gray

# ---------- Step 1: Pre-flight checks ----------
step "Pre-flight checks"

ok "bundled fastboot ready"
ok "bundled payload-dumper-go ready"

if (-not (Get-FastbootState)) {
    die "no device detected in fastboot mode. Boot into fastboot and connect via USB, then rerun."
}
ok "device detected in fastboot"

# ---------- Step 2: Bootloader unlock check ----------
step "Checking bootloader"

$UNLOCKED = Get-FastbootVar -Var "unlocked"
if ($UNLOCKED -eq "yes") {
    ok "bootloader is unlocked"
} else {
    die "bootloader is not unlocked (reported: '$UNLOCKED'). Unlock it before flashing."
}

# ---------- Step 3: Extract rom.zip ----------
step "Preparing images"

if ((Test-Path $IMAGES_DIR -PathType Container) -and (Get-ChildItem $IMAGES_DIR -File).Count -gt 0) {
    ok "'$IMAGES_DIR' already exists, skipping extraction"
    # Sanity-check the cache actually has what we need before trusting it
    $missing = @()
    foreach ($p in ($STATIC_PARTITIONS + $LOGICAL_PARTITIONS)) {
        if (-not (Test-Path "$IMAGES_DIR\$p.img" -PathType Leaf)) {
            $missing += $p
        }
    }
    if ($missing.Count -gt 0) {
        die "'$IMAGES_DIR' exists but is missing images for: $($missing -join ' '). Delete '$ROM_DIR' and rerun to re-extract."
    }
    ok "cached images verified complete"
} else {
    if (-not (Ask-YesNo -Prompt "Make sure '$ROM_ZIP' is in this folder (recovery.img is optional — falls back to payload's if missing). Ready?")) {
        die "place '$ROM_ZIP' in this folder, then rerun."
    }

    if (-not (Test-Path $ROM_ZIP -PathType Leaf)) {
        die "'$ROM_ZIP' not found in current directory ($PWD)."
    }
    ok "$ROM_ZIP found"

    info "unzipping $ROM_ZIP -> ${ROM_DIR}/"
    try {
        Expand-Archive -Path $ROM_ZIP -DestinationPath $ROM_DIR -Force
        ok "extracted"
    } catch {
        die "failed to unzip $ROM_ZIP."
    }

    if (-not (Test-Path "$ROM_DIR\payload.bin" -PathType Leaf)) {
        die "'payload.bin' not found inside $ROM_ZIP."
    }
    ok "payload.bin found"

    info "running payload-dumper-go (this can take a few minutes)..."
    & $PAYLOAD_DUMPER -o $IMAGES_DIR "$ROM_DIR\payload.bin"
    if ($LASTEXITCODE -ne 0) {
        die "payload-dumper-go failed to extract payload.bin."
    }
    ok "images extracted to $IMAGES_DIR"

    $missing = @()
    foreach ($p in ($STATIC_PARTITIONS + $LOGICAL_PARTITIONS)) {
        if (-not (Test-Path "$IMAGES_DIR\$p.img" -PathType Leaf)) {
            $missing += $p
        }
    }
    if ($missing.Count -gt 0) {
        die "extraction finished but missing images for: $($missing -join ' ')."
    }
    ok "all required images present"
}

# ---------- Step 4: Ask flash type ----------
step "Choosing flash type"
Ask-FlashType

# ---------- Step 5: Wipe (clean flash only, after extraction) ----------
step "Wiping ($FLASH_TYPE flash)"

if ($FLASH_TYPE -eq "clean") {
    if (-not (Get-FastbootState)) {
        die "device not in fastboot mode. Boot into fastboot first, then rerun."
    }
    info "running 'fastboot -w'..."
    & $FASTBOOT -w
    if ($LASTEXITCODE -ne 0) { die "'fastboot -w' failed." }
    ok "user data erased"
} else {
    info "dirty flash selected, skipping wipe"
}

# ---------- Step 6: Flash static partitions + recovery ----------
step "Flashing static partitions (bootloader)"

foreach ($partition in $STATIC_PARTITIONS) {
    info "flashing ${partition}..."
    & $FASTBOOT flash $partition "$IMAGES_DIR\$partition.img"
    if ($LASTEXITCODE -eq 0) {
        ok "$partition flashed"
    } else {
        die "failed to flash '$partition'."
    }
}

if (Test-Path $RECOVERY_IMG -PathType Leaf) {
    info "flashing recovery (custom OFOX from root folder)..."
    & $FASTBOOT flash recovery $RECOVERY_IMG
    if ($LASTEXITCODE -ne 0) { die "failed to flash recovery." }
    ok "recovery flashed (custom OFOX)"
} elseif (Test-Path "$IMAGES_DIR\recovery.img" -PathType Leaf) {
    info "flashing recovery (stock, from payload — no custom recovery.img found in root)..."
    & $FASTBOOT flash recovery "$IMAGES_DIR\recovery.img"
    if ($LASTEXITCODE -ne 0) { die "failed to flash recovery." }
    ok "recovery flashed (from payload)"
} else {
    die "no recovery image available — '$RECOVERY_IMG' not found in root and payload didn't produce '$IMAGES_DIR\recovery.img'. Place a custom recovery.img in the root folder and rerun."
}

# ---------- Step 7: Enter fastbootd ----------
step "Entering fastbootd"

info "sending 'fastboot reboot fastboot'..."
& $FASTBOOT reboot fastboot
if ($LASTEXITCODE -ne 0) { die "'fastboot reboot fastboot' failed." }
Wait-Fastbootd -Timeout $FASTBOOTD_WAIT_TIMEOUT

# ---------- Step 8: Flash logical partitions ----------
step "Flashing logical partitions (fastbootd)"

foreach ($partition in $LOGICAL_PARTITIONS) {
    info "flashing ${partition}..."
    & $FASTBOOT flash $partition "$IMAGES_DIR\$partition.img"
    if ($LASTEXITCODE -eq 0) {
        ok "$partition flashed"
    } else {
        die "failed to flash '$partition'. If this says 'not enough space', your previous ROM's partition layout likely differs from ROM's — you'll need to manually delete-logical-partition '$partition' (both _a and _b slots) and retry."
    }
}

# ---------- Step 9: Final reboot ----------
step "Finishing up"

info "rebooting..."
& $FASTBOOT reboot
if ($LASTEXITCODE -eq 0) {
    ok "reboot command sent"
} else {
    warn "'fastboot reboot' failed — reboot manually."
}

Write-Host ""
Write-Host "[*] ROM flash complete ($FLASH_TYPE flash) — $(elapsed)s total" -ForegroundColor Green
Write-Host ""
