# AirQc35

A macOS helper for Bose QC35 headphones that cling to your Mac, steal your microphone, or make switching to your phone a chore.

![Device handoff and headset settings, shown before the AirQc35 rename](docs/images/qc35-control-panel.jpg)

Open AirQc35 from Control Center. Native Liquid Glass, two switches, and one place to hand your headphones to another device. This is an experimental utility tested with a Bose QC35 II.

## What it does

- **Lid release:** closes the configured headset connection when the lid closes, all displays sleep, or the system begins sleeping. The helper never reconnects on wake.
- **Avoid headset mic:** restores a configured preferred microphone, with a configured fallback, while the headset is present. It does not remember an arbitrary previously selected microphone.
- **Device:** hands the headset to the chosen device. Mac selection routes sound to QC35 and releases the other source; phone selection confirms the phone connection before releasing the Mac. The rows are saved destinations, so disconnected devices remain available to select. One checkmark records the last verified handoff.
- **Control Center:** a WidgetKit control opens the companion app. Both switches persist locally and update the running helper.

The helper uses Core Audio, IOBluetooth, IOKit, and AppKit notifications. It has bounded retries and no periodic device polling. The companion uses SwiftUI, AppKit, WidgetKit, and App Intents. No third-party runtime dependencies are required.

## Requirements

The companion currently targets macOS 27 and builds with Xcode 27. The project generator uses Node.js with TypeScript stripping support (Node 22.18 or newer). Development and hardware observations were on Apple silicon with a Bose QC35 II; other Bose models are unverified.

## Install from source

Install full Xcode 27 and Node.js 22.18 or newer first. Launch Xcode once to finish its setup, and select it in Xcode → Settings → Locations → Command Line Tools. Pair and connect your QC35 in macOS Bluetooth settings, then run:

```sh
git clone https://github.com/vanjaoljaca/airqc35.git
cd airqc35
node --experimental-strip-types ControlCenter/Install.ts
```

The installer builds everything from this checkout, installs `~/Applications/AirQc35.app`, detects your headset and a safe microphone, and starts a per-user background helper. No `sudo`, downloaded helper binary, old disconnect script, or configuration from the author's computer is needed. Node and Xcode are build tools only; neither runs in the background.

In macOS's **Add Controls** interface, find **AirQc35** and add its headphone button to Control Center. Clicking it opens the panel. There is no separate menu-bar icon. Allow Bluetooth access if macOS asks, and keep the helper enabled in Login Items for lid and microphone protection.

If you renamed your headset, have more than one QC35, or want to choose the initial microphone explicitly:

```sh
node --experimental-strip-types ControlCenter/Install.ts \
  --headset "Your headset name" --input "Your microphone name"
```

Setup does not guess when names are ambiguous. It preserves an existing configuration byte for byte, including device filters and switch settings. The default microphone choice is your current non-Bluetooth input, with the Mac's built-in microphone as fallback when available. On a desktop Mac without a built-in mic, it uses the selected safe input for both.

To update, run `git pull` and the same install command again. Existing installations named QC35 are migrated to AirQc35 without resetting preferences. macOS may retain the old name on an existing Control Center button; remove and re-add that button if needed. Builds use local ad-hoc signing; this repository does not provide a notarized download.

### Settings and removal

The helper and app share `~/Library/Application Support/QC35InputGuard/config.json`. The internal folder and service names stay stable across the rename. You can change microphone preference without reinstalling:

```sh
"$HOME/Library/Application Support/QC35InputGuard/QC35InputGuard" prefer "Your microphone name"
"$HOME/Library/Application Support/QC35InputGuard/QC35InputGuard" status
```

An empty `visibleSourceAddresses` array shows all saved headset sources, including offline pairings. To narrow the list, use addresses from the locally generated `ControlCenter/sources.json` cache. Keep that cache and your configuration private. Opening the panel queries an already-connected headset; connecting is an explicit device action.

Uninstall the app and background service while preserving your settings:

```sh
node --experimental-strip-types ControlCenter/Install.ts --uninstall
```

Logs are local in `~/Library/Logs/QC35InputGuard`. The service is `com.vanja.qc35.inputguard`. There is one native Swift helper; it directly uses macOS APIs for connection release and microphone protection. Do not start a second `watch` process alongside the installed service.

### Build without installing

```sh
node --experimental-strip-types ControlCenter/Install.ts --build-only
```

This creates the helper and Release app under `build/` without changing settings, installing a service, or opening the app.

## Tests

These checks use fake devices and protocol fixtures; they do not change real audio, Bluetooth, or sleep state.

```sh
mkdir -p build/tests
cp QC35InputGuard.swift build/tests/main.swift
xcrun swiftc -O -warnings-as-errors -D QC35_TEST \
  build/tests/main.swift QC35ReleaseTests.swift -o build/tests/QC35ReleaseTests
build/tests/QC35ReleaseTests
xcrun swiftc -O -warnings-as-errors -parse-as-library -D BOSE_SOURCE_PROBE \
  ControlCenter/App/BoseSources.swift -o build/tests/BoseSourceProbe
build/tests/BoseSourceProbe --self-test
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -D QC35_HANDOFF_TEST ControlCenter/App/MacConnection.swift \
  ControlCenter/App/BoseSources.swift -o build/tests/QC35HandoffTests
build/tests/QC35HandoffTests
xcrun swiftc -swift-version 5 -warnings-as-errors -parse-as-library \
  -D QC35_MODEL_TEST ControlCenter/App/QC35Model.swift \
  ControlCenter/App/MacConnection.swift ControlCenter/App/BoseSources.swift \
  -o build/tests/QC35SelectionCacheTests
build/tests/QC35SelectionCacheTests
node --experimental-strip-types --test ControlCenter/Install.test.ts
```

The Swift suite contains 43 policy/configuration/setup tests, 21 offline protocol and selection checks, 13 native-operation lifecycle checks, and 3 selection-cache checks. Another 19 installer tests exercise clean installation, upgrades, service ownership, symlinked checkouts, and failure handling with isolated files and a simulated service manager.

## Known limits

- Phone handoff has been verified by a fresh phone-connected status followed by confirmed Mac disconnection. Once the Mac is released, the panel retains the last verified destination because it cannot query the headset without reconnecting. This does not prove phone audio playback has started.
- The destination must have Bluetooth enabled and be reachable. Saved pairings are not proof that a device is currently online. The app does not turn on another device's Bluetooth, start its playback, or remove any pairing.
- Physical lid-close/sleep release and subsequent phone playback still need a hardware acceptance check.
- The popup uses Apple's regular Liquid Glass material for text legibility, with a single native `NSGlassEffectView` and no extra blur layer. Its appearance follows macOS settings and the content behind the panel.
- Apple's public Control Center API offers buttons and toggles. A custom expanded Control Center panel like Apple's Bluetooth UI is not exposed by the APIs used here.
- Release and microphone protection are reactive. macOS can briefly select the headset input before the helper responds, and an app that chooses its own input can bypass the default-input policy.
- Microphone protection waits if neither configured safe input is uniquely available. Releasing a Bluetooth connection is not proof that another device has begun playing audio.

## Source map

- `QC35InputGuard.swift`: event-driven microphone and connection-release helper.
- `QC35ReleaseTests.swift`: fake-device policy and configuration tests.
- `ControlCenter/App/`: companion UI, model, Mac connection, and Bose serial protocol.
- `ControlCenter/Widget/`: Control Center button.
- `ControlCenter/Shared/`: foreground App Intent.
- `ControlCenter/BuildProject.ts`: reproducible Xcode project generator.
- `ControlCenter/Install.ts`: source build, first-run setup, service installation, updates, and uninstall.

Live configuration, device caches, logs, old machine-specific deployment scripts, receipts, and binaries are excluded from this repository.

## Native API references

- [Core Audio default input](https://developer.apple.com/documentation/coreaudio/kaudiohardwarepropertydefaultinputdevice)
- [IOBluetooth connection release](https://developer.apple.com/documentation/iobluetooth/iobluetoothdevice/closeconnection())
- [WidgetKit controls](https://developer.apple.com/documentation/widgetkit/controls-collection)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass)
- [NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)

This is an independent project, not an official Bose product.

## Protocol references

The Swift serial implementation was informed by the protocol layouts in [BoseConnect-Linux_based-connect](https://github.com/bosefirmware/BoseConnect-Linux_based-connect), a fork of Denton-L/based-connect published under GPLv3, and [aaronsb/bosectl](https://github.com/aaronsb/bosectl), published under the MIT license (copyright 2026 Aaron Bockelie). These references supplied packet framing, source-list/detail and connection message meanings, status values, and transport context. Protocol observations were then checked against a QC35 II. No external implementation is vendored in this repository.
