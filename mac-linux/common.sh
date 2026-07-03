#!/usr/bin/env bash
#
# common.sh — bundled binary resolution for marble-flashing-kit
#
# Sourced by the flash_*.sh scripts. Expects die() to be defined by the caller.

# Resolve the directory containing the running script.
# When sourced, BASH_SOURCE[0] is this helper; because common.sh lives in the
# repository root alongside the main scripts, this yields the toolkit root.
# If the caller already set SCRIPT_DIR, keep that value.
if [ -z "${SCRIPT_DIR:-}" ]; then
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

# Detect host OS.
case "$(uname -s)" in
    Darwin*) OS="darwin" ;;
    Linux*)  OS="linux" ;;
    *)       OS="unknown" ;;
esac

# Remove macOS quarantine from bundled binaries so they can execute.
# This only runs on macOS and only affects the tool directories.
if [ "$OS" = "darwin" ]; then
    xattr -dr com.apple.quarantine "${SCRIPT_DIR}/platform-tools-darwin" 2>/dev/null || true
    xattr -dr com.apple.quarantine "${SCRIPT_DIR}/payload-dumper-go-darwin" 2>/dev/null || true
fi

# Resolve a bundled executable path.
# Verify it exists and is executable; chmod +x once if needed.
# Usage: path=$(resolve_bundled_tool "subdir" "filename")
resolve_bundled_tool() {
    local subdir="$1"
    local filename="$2"
    local bin_path="${SCRIPT_DIR}/${subdir}/${filename}"

    if [ ! -e "$bin_path" ]; then
        die "Bundled $filename binary missing:
${subdir}/${filename}

Your toolkit appears incomplete."
    fi

    if [ ! -x "$bin_path" ]; then
        if ! chmod +x "$bin_path" 2>/dev/null; then
            die "Bundled $filename binary is not executable and could not be made executable:
${subdir}/${filename}"
        fi
        if [ ! -x "$bin_path" ]; then
            die "Bundled $filename binary is still not executable after chmod +x:
${subdir}/${filename}

Your toolkit appears incomplete."
        fi
    fi

    printf '%s\n' "$bin_path"
}
