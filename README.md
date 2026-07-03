# marble-flashing-kit

Scripts to flash firmware and custom ROMs on Poco F5 / Redmi Note 12 Turbo (marble).
Works on Windows, macOS, and Linux. All required tools (adb, fastboot, payload-dumper-go)
are bundled — no manual setup needed.

## Prerequisites

- Unlocked bootloader
- USB cable (preferably the original one)
- At least 50% battery

## Steps

1. Download your ROM's fastboot package and place it in `mac-linux/` (or `windows/`), rename to `rom.zip`
2. Download firmware for your variant from [xiaomifirmwareupdater.com](https://xiaomifirmwareupdater.com/firmware/marble/) and place it as `firmware.zip`
3. (Optional) If the ROM maintainer requires a custom recovery, place it as `recovery.img`
4. (Windows only) Right-click `windows/install_drivers.cmd` -> Run as administrator
5. Reboot to bootloader using one of these methods:
   ```
   adb reboot bootloader
   ```
   Or power off, then hold **Volume Down + Power**
6. Flash firmware and ROM:

   **macOS/Linux:**
   ```
   cd mac-linux
   ./flash_firmware_fastboot.sh
   ./flash_rom_fastboot.sh
   ```

   **Windows:**
   Open the `windows/` folder, then right-click each of these -> Run as administrator:
   - `flash_firmware_fastboot.cmd`
   - `flash_rom_fastboot.cmd`

   The ROM script will ask if you want a dirty flash (keep data) or clean flash (wipe data).

## Notes

- `.cmd` scripts are for Windows (right-click -> Run as administrator)
- `.sh` scripts are for macOS/Linux
- Warnings about `avb footer` during firmware flash are normal, ignore them
- Device will reboot into fastbootd automatically during ROM flash — this is expected
- These scripts **do not** wipe data unless you select clean flash
- First boot can take 5-10 minutes. If stuck longer than 15 minutes, force reboot.
