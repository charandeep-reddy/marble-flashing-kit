# 📱 Poco F5 Flashing Kit (marble)

Flash custom ROMs and firmware on your **Poco F5 / Redmi Note 12 Turbo** — no manual setup, no hunting for tools. Everything you need is bundled inside this folder.

Works on **Windows, macOS, and Linux**.

---

## ⚠️ Before You Start

- **Your bootloader MUST be unlocked.** If it isn't, nothing here will work. Search "Xiaomi bootloader unlock" if you haven't done it yet.
- **Backup your data.** Photos, chats, files — copy them somewhere safe. You can flash without wiping, but things can go wrong.
- **Battery should be at least 50%.** Don't let your phone die mid-flash.
- **Use a good USB cable.** Not the one you charge your headphones with. Original cable or a thick data cable.

---

## 📦 What You Need to Download (you bring these)

| File | Where to get it | Rename to |
|------|----------------|-----------|
| Your ROM | From the ROM developer's page (e.g. Axion, Evolution X, crDroid) | `rom.zip` |
| Firmware | [xiaomifirmwareupdater.com](https://xiaomifirmwareupdater.com/firmware/marble/) — pick your region (Global, India, EEA, China) | `firmware.zip` |
| Recovery *(optional)* | Only if the ROM maintainer says you need custom recovery (e.g. OFOX, TWRP) | `recovery.img` |

**Place all files inside the `mac-linux/` folder** (or `windows/` if you're on Windows).

---

## 🚀 How to Flash (macOS / Linux)

### Step 1: Reboot to bootloader

Connect your phone to the computer via USB. Then:

```
adb reboot bootloader
```

Or manually: power off → hold **Volume Down + Power** until you see the fastboot screen (usually a bunny fixing Android).

### Step 2: Open the terminal

```bash
cd marble-flashing-kit/mac-linux
```

### Step 3: Flash firmware

```bash
./flash_firmware_fastboot.sh
```

This updates the low-level radio / modem / security firmware. Takes about 30 seconds. If you see warnings about `avb footer`, ignore them — that's normal.

### Step 4: Flash the ROM

```bash
./flash_rom_fastboot.sh
```

The script will:
1. Check your bootloader is unlocked
2. Extract the ROM (this takes a couple of minutes)
3. Ask **Dirty flash** (keep your apps/data) or **Clean flash** (fresh start)
4. If you placed a `recovery.img` in the folder, it'll flash that as your custom recovery
5. Flash everything else automatically
6. Reboot your phone when done

> **First time flashing this ROM?** Pick **Clean flash** (option 2).
> **Updating an existing ROM?** Pick **Dirty flash** (option 1).

### Step 5: First boot

The first boot can take **5–10 minutes**. If it's stuck longer than 15 minutes, force reboot by holding Power for 10 seconds.

---

## 🪟 How to Flash (Windows)

1. Right-click `windows/install_drivers.cmd` → **Run as administrator** (one-time setup)
2. Put `rom.zip`, `firmware.zip`, and `recovery.img` *(if needed)* inside the `windows/` folder
3. Reboot phone to bootloader (see Step 1 above)
4. Open the `windows/` folder in File Explorer
5. Right-click `flash_firmware_fastboot.cmd` → **Run as administrator**
6. Then right-click `flash_rom_fastboot.cmd` → **Run as administrator**

---

## 🔄 Alternative: Flash via Recovery (Sideload)

If fastboot isn't working or you prefer flashing from recovery (TWRP / OFOX):

| What | macOS/Linux | Windows |
|------|-------------|---------|
| Firmware | `./flash_firmware_sideload.sh` | Right-click → Run as admin |
| ROM | `./flash_rom_sideload.sh` | Right-click → Run as admin |

The sideload scripts will:
1. Reboot your phone into recovery automatically
2. Trigger sideload mode
3. Push the zip over USB
4. Let you choose dirty or clean flash (ROM only)
5. Ask if you want to reboot to system when done

---

## ❓ Common Questions

**Q: What's the difference between firmware and ROM?**
**Firmware** = the low-level stuff (radio, camera, boot chain). **ROM** = the actual Android system you interact with. Flash firmware once per ROM install, then only flash the ROM for updates.

**Q: When do I need recovery.img?**
Only if the ROM developer or maintainer says to. Some ROMs require a custom recovery (like OFOX or TWRP) to flash properly. If they don't mention it, you don't need it. If you place a `recovery.img` in the folder, the fastboot script will flash it automatically.

**Q: Will my photos/files get deleted?**
Not unless you pick **Clean flash**. Dirty flash keeps everything. That said — **always have a backup** because phones don't care about your plans.

**Q: The screen looks frozen / shows encrypted files after flashing**
That's normal. Wait 8 seconds — the phone is switching between USB modes. It'll sort itself out.

**Q: "Not enough space" error when flashing logical partitions?**
Your previous ROM used a different partition layout. You'll need to manually delete the old logical partitions (both _a and _b slots) via fastboot and retry. Search "fastboot delete-logical-partition" for your specific ROM.

**Q: I see avb footer warnings during firmware flash**
Ignore them. They're informational, not errors.

**Q: First boot is stuck on the logo for a long time**
First boot can take 5–10 minutes. If it's been 15+ minutes, force reboot (hold Power 10 seconds). If it still doesn't boot, try a clean flash.

---

## 🗺️ Quick Reference

```
Phone off → Volume Down + Power = Bootloader (fastboot mode)
Select "Reboot to bootloader" from recovery = Bootloader
fastboot reboot fastboot = Fastbootd (for logical partitions)
fastboot reboot recovery = Recovery mode
```

---

## 🛟 Need Help?

- Your ROM's Telegram group or XDA thread is the best place to ask
- Search the error message — someone has almost certainly hit it before
- If a cable isn't working, try a different port (USB 2.0 ports are more reliable than USB 3.0)
