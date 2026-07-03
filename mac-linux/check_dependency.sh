check_dependency() {
    if command -v "$1" >/dev/null 2>&1; then
        echo "✅ Found: $1"
    else
        echo "❌ Missing: $1"
        exit 1
    fi
}

check_dependency adb
check_dependency fastboot
check_dependency unzip
check_dependency payload-dumper-go