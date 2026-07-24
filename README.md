# GlanceHUD iPhone App

Native iPhone app for a BLE-powered HUD glasses prototype.

## Tech Stack

- Swift 5
- SwiftUI
- CoreBluetooth
- CoreLocation
- iOS 15+
- Xcode latest stable release

## Recommended BLE UUIDs

- HUD Service: `B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C001`
- Write Characteristic: `B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C002`
- Notify Characteristic: `B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C003`

## BLE Payload Format

The app sends newline-terminated UTF-8 JSON. If a JSON packet is longer than the negotiated BLE write size, the iPhone app automatically chunks it into multiple BLE writes.

Example logical packets:

```json
{"type":"clock","text":"22:35"}
{"type":"date","text":"2026-07-24"}
{"type":"weather","text":"26C"}
{"type":"battery","text":"83%"}
{"type":"message","text":"Never Give Up"}
```

ESP32 firmware should buffer incoming bytes until `\n`, then parse the full JSON line.

## Build

1. Open [HUDApp.xcodeproj](/C:/Users/JHCWColin/Desktop/GlanceHUD/HUDApp.xcodeproj).
2. Set your Apple Development Team in Signing.
3. Build and run on a real iPhone.
4. Ensure the ESP32 advertises as `GlanceHUD`, `HUD Glasses`, or `XIAO-HUD`.
5. Ensure the ESP32 exposes the service/characteristics above and advertises the custom service UUID if possible.

## Firmware Build (Arduino CLI)

Firmware sketch:

- [固件/GlanceHUD_XIAO_ESP32S3/GlanceHUD_XIAO_ESP32S3.ino](/C:/Users/JHCWColin/Desktop/GlanceHUD/固件/GlanceHUD_XIAO_ESP32S3/GlanceHUD_XIAO_ESP32S3.ino)

Verified local compile target:

- FQBN: `esp32:esp32:XIAO_ESP32S3`

Required Arduino libraries:

- `Adafruit GFX Library`
- `Adafruit SSD1306`
- `ArduinoJson`

Compile command:

```powershell
arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3 --build-path .arduino-build\GlanceHUD_XIAO_ESP32S3 "固件\GlanceHUD_XIAO_ESP32S3\GlanceHUD_XIAO_ESP32S3.ino"
```

If you are building from mainland China, use Espressif's China package index mirror and install a `-cn` ESP32 core release such as `esp32:esp32@3.3.10-cn`.

## Notes

- Weather uses Open-Meteo and current GPS location.
- Battery uses `UIDevice` battery monitoring, which is the only UIKit dependency in the project.
- Background protection is enabled with `bluetooth-central` and CoreBluetooth state restoration.
- Continuous 1-second clock sync is reliable while the app is in the foreground. iOS does not guarantee indefinite per-second timer execution after the app is fully backgrounded.

## GitHub Actions Release Build

The repository includes [.github/workflows/ios-release.yml](/C:/Users/JHCWColin/Desktop/GlanceHUD/.github/workflows/ios-release.yml:1).

- Trigger modes: manual `workflow_dispatch`, or every pushed tag.
- Simulator output: `HUDApp-<tag>-simulator.zip`
- Device output: `HUDApp-<tag>-device-unsigned.ipa`
- Release upload target: the GitHub Release that matches the tag

The device IPA is intentionally unsigned. It is useful as a release artifact, but it is not directly installable on a normal iPhone until it is signed with a valid Apple identity and provisioning profile.
