@echo off
setlocal
cd /d "%~dp0"

powershell -NoProfile -Command "Write-Host ''; Write-Host '  Installing Google Android USB Driver' -ForegroundColor Blue; Write-Host ''"

if not exist "usb_driver-windows\android_winusb.inf" (
    powershell -NoProfile -Command "Write-Host '  ! Driver files not found. Make sure usb_driver-windows\ exists.' -ForegroundColor Red"
    pause
    exit /b 1
)

powershell -NoProfile -Command "Write-Host '  >> Running pnputil to install driver...' -ForegroundColor Cyan"
pnputil /add-driver "usb_driver-windows\android_winusb.inf" /install

echo.
powershell -NoProfile -Command "Write-Host '  [OK] Google USB driver installed (or already present).' -ForegroundColor Green"
powershell -NoProfile -Command "Write-Host '  If your device still is not detected, try:' -ForegroundColor Gray"
powershell -NoProfile -Command "Write-Host '    - Xiaomi USB Driver (search Google for your model)' -ForegroundColor Gray"
powershell -NoProfile -Command "Write-Host '    - Different USB cable/port' -ForegroundColor Gray"
powershell -NoProfile -Command "Write-Host '    - Enable USB debugging on the phone' -ForegroundColor Gray"

echo.
pause
