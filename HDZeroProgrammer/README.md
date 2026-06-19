# HDZero Programmer

A native macOS (SwiftUI) app to **flash HDZero gear** — VTX, goggles/VRX, and the ELRS radio —
without the Windows-only vendor tools. It wraps the right flasher per device behind one UI:

| Device | Method |
|---|---|
| **VTX** (SPI flash) | bundled **`flashrom`** via a **CH341A** USB programmer clipped to the flash chip (runs `flashrom` as root once per flash — macOS asks for your admin password) |
| **VTX** (native) | direct **CH341 SPI** over IOKit USB (no `flashrom`) |
| **ELRS radio / module** | **esptool** + XMODEM/serial flashing |
| **Event VRX / goggles** | firmware download + flash |
| **Monitor** | live device status / settings |

Firmware is fetched from the official catalog at flash time.

## Build / run

```bash
./build_app.sh          # compiles, embeds flashrom (+ dylibs), signs (Developer ID),
                        # notarizes, and packages "HDZero Programmer.app" + a .dmg
open "HDZero Programmer.app"
```

`DO_NOTARIZE=0 ./build_app.sh` skips notarization for a quick local build.

Build-time requirements (dev Mac): Xcode toolchain, Homebrew **`flashrom`** and **`dylibbundler`**.
The shipped app is **fully portable** — `flashrom` and its dynamic libraries (`libftdi1`, `libusb`,
`libcrypto`) are embedded in `Contents/Resources/flashrom/`, relinked to `@executable_path`. No
Homebrew/flashrom needed on the target Mac.

## Install

Download the `.dmg` from the repo's [**Releases**](../../releases), drag **HDZero Programmer** to
`/Applications`, and launch. Apple-signed + notarized — no Terminal/`xattr` workaround. Requires
macOS 13 (Ventura) or newer.

> ⚠️ Flashing hardware can brick a device if interrupted or mis-targeted. Use at your own risk; make
> sure you pick the correct firmware for your gear.

## Hardware (VTX via flashrom)

A **CH341A** USB programmer with a SOIC clip on the VTX's SPI flash chip, VTX powered as instructed.
