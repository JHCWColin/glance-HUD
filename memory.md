# GlanceHUD Session Memory

## Repository state

- Local workspace: `C:\Users\JHCWColin\Desktop\GlanceHUD`
- Remote repository: `https://github.com/JHCWColin/glance-HUD.git`
- Active branch: `main`
- Current `main` HEAD on 2026-07-24: `ad9a6ab` (`Add XIAO ESP32-S3 firmware and BLE diagnostics`)
- Initial commit: `2ede414` (`Add native HUD iOS app and release workflow`)

## Git / workspace notes

- The broken empty `.git` directory from the start of the project was preserved as `.git.broken`.
- A fresh Git repository was initialized successfully and connected to `origin`.
- `gh` now works in the current Codex session and is authenticated as `JHCWColin`.
- Current untracked local files:
  - `gha-run-30103281755-job-89514419110.log`
  - `memory.md`
- The user said they will restart Codex after this session so the next session can use `arduino-cli`.

## iOS app state

- Native SwiftUI iPhone app exists and is pushed.
- GitHub Actions workflow exists at `.github/workflows/ios-release.yml`.
- Packaging script exists at `scripts/package_ios_artifacts.sh`.
- Shared scheme exists at `HUDApp.xcodeproj/xcshareddata/xcschemes/HUDApp.xcscheme`.
- The app now recognizes BLE device names:
  - `GlanceHUD`
  - `HUD Glasses`
  - `XIAO-HUD`

## BLE diagnostics added on 2026-07-24

- `BLEService.swift` now reports:
  - runtime environment: simulator vs physical iPhone
  - current BLE workflow step
  - failure step
  - failure reason
  - analysis text for the current block/failure
- `HomeView.swift` now shows a dedicated `BLE Diagnostics` card.
- If the app runs in iOS Simulator, it explicitly reports that BLE hardware is unavailable there and disables the `Scan` button.

## Firmware state

- New firmware sketch directory created:
  - `固件/GlanceHUD_XIAO_ESP32S3/GlanceHUD_XIAO_ESP32S3.ino`
- Target hardware:
  - Seeed Studio XIAO ESP32-S3
  - 0.49 inch OLED
  - SSD1315
  - 64x32
  - I2C
- OLED wiring assumed in firmware:
  - OLED `VCC` -> XIAO `3V3`
  - OLED `GND` -> XIAO `GND`
  - OLED `SDA` -> XIAO `D4`
  - OLED `SCL` -> XIAO `D5`
- Firmware behavior implemented:
  - initializes OLED
  - starts BLE server
  - advertises as `GlanceHUD`
  - creates service `B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C001`
  - creates write characteristic `B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C002`
  - creates notify characteristic `B9FEC7E0-54B1-4E6C-8A0D-44A3D8B7C003`
  - shows `GlanceHUD` / `Waiting...` on boot
  - receives UTF-8 JSON delimited by `\n`
  - parses JSON with `ArduinoJson`
  - handles `clock`, `date`, `weather`, `battery`, `message`
  - updates OLED display and refreshes automatically
  - outputs serial debug logs at `115200`
  - restarts BLE advertising after disconnect

## Arduino environment expectations for next session

- The user intends the next Codex session to have `arduino-cli` available after restart.
- Current session did not have `arduino-cli` in PATH.
- Expected Arduino libraries for the firmware:
  - `Adafruit GFX Library`
  - `Adafruit SSD1306`
  - `ArduinoJson`
- BLE headers are expected from the ESP32 board package rather than a separate Arduino library.

## Arduino CLI verification on 2026-07-24

- `arduino-cli` is now available in PATH:
  - `arduino-cli 1.5.1`
- Verified local compile target:
  - `esp32:esp32:XIAO_ESP32S3`
- Verified working ESP32 core for this network environment:
  - `esp32:esp32@3.3.10-cn`
- Installed Arduino libraries:
  - `Adafruit GFX Library@1.12.6`
  - `Adafruit SSD1306@2.5.17`
  - `ArduinoJson@7.4.3`
- Working compile command:
  - `arduino-cli compile --fqbn esp32:esp32:XIAO_ESP32S3 --build-path .arduino-build/GlanceHUD_XIAO_ESP32S3 固件/GlanceHUD_XIAO_ESP32S3/GlanceHUD_XIAO_ESP32S3.ino`
- China-network setup that worked for downloads:
  - `HTTP_PROXY=http://localhost:7890`
  - `HTTPS_PROXY=http://localhost:7890`
  - `ARDUINO_BOARD_MANAGER_ADDITIONAL_URLS=https://jihulab.com/esp-mirror/espressif/arduino-esp32/-/raw/gh-pages/package_esp32_index_cn.json`
- Important mirror nuance:
  - plain `esp32:esp32@3.3.11` still tried to fetch toolchains from GitHub and timed out
  - installing the `-cn` package line was required in this environment
- Firmware compatibility fix made during compile verification:
  - `BLECharacteristic::getValue()` is handled as `String` in `GlanceHudWriteCallbacks`
  - removed now-unneeded `<string>` include
- `README.md` now includes Arduino CLI firmware build instructions and updated supported BLE device names.

## GitHub Actions timeline on 2026-07-24

### Run `30103000665`

- Trigger: tag push `v0.1.0`
- Conclusion: `failure`
- Failed step: `Build simulator and unsigned device artifacts`
- Early root cause investigated:
  - original packaging script used `mapfile`
  - macOS runner Bash 3.2 compatibility issue

### Run `30103281755`

- Trigger: tag push `v0.1.1`
- Conclusion: `failure`
- Failed step: `Build simulator and unsigned device artifacts`
- Job ID: `89514419110`
- Main root cause found from logs:
  - Swift actor isolation issues in `BLEService` and `LocationService`
  - default initialization of main-actor services in `BLEViewModel`

### Commit / fix sequence after `v0.1.1`

- Commit `e8e14c5`: `Fix actor isolation in iOS services`
- Tag `v0.1.2` created and pushed
- Run `30104067056` for `v0.1.2` failed
- New root cause:
  - `BLEViewModel` incorrectly used `override init()` and `super.init()` even though it has no superclass

- Commit `7970eef`: `Fix BLEViewModel initializer`
- Tag `v0.1.3` created and pushed

### Run `30104252138`

- Trigger: tag push `v0.1.3`
- Conclusion: `success`
- Job ID: `89517654829`
- GitHub Release `v0.1.3` exists and contains:
  - `HUDApp-v0.1.3-simulator.zip`
  - `HUDApp-v0.1.3-device-unsigned.ipa`

### Latest code push on 2026-07-24

- Commit `ad9a6ab`: `Add XIAO ESP32-S3 firmware and BLE diagnostics`
- This commit includes:
  - ESP32-S3 Arduino firmware sketch
  - app-side BLE diagnostics UI and state tracking
  - `GlanceHUD` device-name support in the iPhone app

### Manual workflow run `30106423256`

- Trigger: `workflow_dispatch` on branch `main`
- Requested release tag: `v0.1.4`
- Conclusion: `success`
- Job ID: `89524858579`
- Run URL: `https://github.com/JHCWColin/glance-HUD/actions/runs/30106423256`
- GitHub Release `v0.1.4` exists and contains:
  - `HUDApp-v0.1.4-simulator.zip`
  - `HUDApp-v0.1.4-device-unsigned.ipa`

## Historical next steps before Arduino CLI verification

1. Verify `arduino-cli` is available:
   - `arduino-cli version`
2. If available, compile the firmware sketch locally:
   - `固件/GlanceHUD_XIAO_ESP32S3/GlanceHUD_XIAO_ESP32S3.ino`
3. If local Arduino compile fails, fix board-package or library assumptions.
4. If local Arduino compile succeeds, optionally add Arduino build instructions to `README.md`.
5. Flash the XIAO ESP32-S3 and test BLE connection from the iPhone app on a real device.

## Current recommended next steps after restart

1. Flash `固件/GlanceHUD_XIAO_ESP32S3/GlanceHUD_XIAO_ESP32S3.ino` to the XIAO ESP32-S3.
2. Confirm the OLED boot screen shows `GlanceHUD` and `Waiting...`.
3. Confirm BLE advertising name is `GlanceHUD`.
4. Test connection from the iPhone app on a real device.
5. Send newline-terminated JSON packets and verify OLED updates for `clock`, `date`, `weather`, `battery`, and `message`.
6. If runtime behavior fails, inspect serial logs at `115200`.
