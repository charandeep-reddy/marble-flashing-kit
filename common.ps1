# common.ps1 — bundled binary resolution for axion-flashing-kit
# Dot-sourced by the flash_*.ps1 scripts.

$Script:KitRoot = $PSScriptRoot

function Resolve-BundledTool {
    param(
        [Parameter(Mandatory)]
        [string]$SubDir,

        [Parameter(Mandatory)]
        [string]$FileName
    )

    $path = Join-Path -Path $Script:KitRoot -ChildPath "$SubDir\$FileName"

    if (-not (Test-Path -Path $path -PathType Leaf)) {
        Write-Host ""
        Write-Host "  ✗ ERROR: Bundled $FileName binary missing:" -ForegroundColor Red
        Write-Host "  $SubDir\$FileName" -ForegroundColor Red
        Write-Host ""
        Write-Host "  Your toolkit appears incomplete." -ForegroundColor Red
        Write-Host ""
        exit 1
    }

    return $path
}
