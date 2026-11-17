# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A native macOS menu-bar app that controls any standards-compliant **USB Video Class (UVC)** webcam. The repo is split into a Swift Package providing the headless, testable core (`LensBarCore`) and an Xcode project (`LensBar/LensBar.xcodeproj`) that builds the `.app` bundle around it. Two control paths are combined:

- **AVFoundation** — focus/exposure auto-or-locked, format and frame-rate switching.
- **IOKit `IOUSBHostDevice`** — UVC Processing Unit and Camera Terminal controls via EP0 class-specific control transfers.

The IOKit path is what makes this app possible. macOS's `UVCAssistant` daemon holds exclusive ownership of `IOUSBHostInterface@0`, which blocks libusb-style access. But the *device node* (`IOUSBHostDevice`) is not held by `UVCAssistant`, so EP0 class-specific requests sent at the device level (not the interface) go through without claiming any interface.

The app was originally developed against the OBSBOT Meet SE but is now camera-agnostic: unit IDs are discovered from the device's USB configuration descriptor, controls are probed via `GET_INFO`, and UI hides anything the connected camera doesn't expose.

## Building and Running

```bash
# Build & test the headless core (fast loop)
swift build
swift test

# Build / archive the app bundle (must go through Xcode)
xcodebuild -project LensBar/LensBar.xcodeproj -scheme LensBar -configuration Release \
  -archivePath build/LensBar.xcarchive archive
```

`swift run` is not used — the `.app` bundle, entitlements, codesigning, and `MenuBarExtra` accessory activation all require the Xcode build path.

## Release Pipeline

Pushing a `v*` tag (or a manual `workflow_dispatch` with a `tag` input) runs `.github/workflows/release.yml`, which builds two signed, notarized, stapled DMGs in parallel, both on `macos-26` — `LensBar.dmg` (arm64-only, `ARCHS=arm64` with `-destination "platform=macOS,arch=arm64"`; Release has `ONLY_ACTIVE_ARCH = NO`, so without `ARCHS` it comes out universal) and `LensBar-universal.dmg` (arm64+x86_64, `ARCHS="arm64 x86_64"` with `-destination "generic/platform=macOS"`; no Intel-hosted runner is needed since the macOS SDK cross-targets x86_64 from Apple Silicon) — attaches both to a GitHub Release, then renders `Casks/lensbar.rb.tmpl` (substituting version + both DMG checksums) and pushes the result as `Casks/lensbar.rb` to the `andrew-craig/homebrew-tap` repo via a `HOMEBREW_TAP_TOKEN` PAT secret. The published cask uses `on_arm`/`on_intel` to pick the right DMG per architecture. Users install with `brew install andrew-craig/tap/lensbar`.

Pre-releases: a tag with a `-` suffix (`v1.2.0-rc1`), or `workflow_dispatch` with `prerelease: true`, marks the GitHub release as a pre-release and skips the Homebrew tap. `MARKETING_VERSION` gets the numeric part only (`1.2.0`). A dispatch run creates its tag on the commit it built (`target_commitish: github.sha`), so it can run from a feature branch.

Signing: both build jobs run the `.github/actions/setup-signing` composite action, which imports the Developer ID certificate and installs two Developer ID provisioning profiles — one for `com.andrewcraig.LensBar` (must include `com.apple.developer.system-extension.install`) and one for `com.andrewcraig.LensBar.Camera` — from the `APP_PROVISIONING_PROFILE_BASE64` and `CAMERA_PROVISIONING_PROFILE_BASE64` secrets. It rejects a profile with the wrong bundle ID, a non-Developer-ID (development) profile, a missing System Extension entitlement or an expired one, and outputs the profile names. A command-line `PROVISIONING_PROFILE_SPECIFIER` would apply to every target, so the project's Release configs read it from per-target variables instead (`LENSBAR_APP_PROFILE`, `LENSBAR_CAMERA_PROFILE`, defaulting to "LensBar Developer ID" / "LensBar Camera Developer ID"); the workflow overrides them and patches the same names into `ExportOptions.plist`'s `provisioningProfiles`. `scripts/verify-signing.sh <app> <codesign|pre-notarize|post-staple> [archs]` checks the signature, Developer ID authority, hardened runtime, timestamps, embedded profiles, entitlements (app: system-extension.install, unsandboxed; extension: sandbox, team app group, Mach service name), architectures and Gatekeeper; the workflow runs it before notarizing and after stapling. Run the `codesign` stage locally against a Debug build.

CI (`.github/workflows/ci.yml`) runs `swift build` / `swift test` and an unsigned universal Release `xcodebuild build` (`CODE_SIGNING_ALLOWED=NO`) on `macos-26`, so app-target and camera-extension compile breaks show up on PRs.

The cask has `uninstall quit:` and a `caveats` note: `brew uninstall` can't deactivate the system extension, so users should remove LensBar Camera from the app first.

Both build jobs must run on the same runner image (currently `macos-26`) so the `.xcodeproj`'s pbxproj format stays openable — an older image pinned to a stale default Xcode (e.g. `macos-14`'s Xcode 15.4) will fail with "future Xcode project file format" once the project is saved by a newer Xcode.

## Layout

- `Package.swift` — three targets: `IOKitUSB` (ObjC, links `IOUSBHost` + `IOKit`), `VirtualCameraKit` (Foundation-only virtual-camera constants and pure logic, shared with the sandboxed extension) and `LensBarCore` (Swift library with the headless camera control + SwiftUI views). No `@main` lives in the package.
- `Sources/VirtualCameraKit/` — `VirtualCameraIdentity` (device UID, extension bundle ID), `VirtualCameraProperty` (custom CMIO properties `lbcc` client count, `lbfm` format), `VirtualCameraFormat` (string codec for the advertised format), `AdvertisedFormatState` (format changes only at zero clients, PLAN.md §4.5), `FormatStore`, `FrameRateEstimator`. Must not import IOKit or AVFoundation.
- `Sources/IOKitUSB/UVCDeviceController.{h,m}` — thin ObjC wrapper around `IOUSBHostDevice`. Sends UVC class-specific GET/SET requests on EP0, plus standard `GET_DESCRIPTOR` for runtime topology discovery. Kept in ObjC so Swift doesn't need an unsafe bridging header for IOUSBHost. Opens by USB location ID so it can pair with an arbitrary `AVCaptureDevice` (a VID/PID initializer remains for tests).
- `Sources/LensBar/UVCTypes.swift` — UVC request codes, `PUControl` / `CTControl` selectors, `AEMode` bitmap values. All standard UVC 1.5 — no device-specific identity.
- `Sources/LensBar/UVCDescriptorParser.swift` — pure-Swift TLV walker over a USB configuration descriptor. Extracts the VideoControl interface number, Camera Terminal ID (input terminal with `wTerminalType=0x0201`), and Processing Unit ID. Either unit may be nil; the UI degrades accordingly.
- `Sources/LensBar/IOKitUVCController.swift` — Swift façade over `UVCDeviceController`. Takes a discovered `UVCTopology` at init, probes per-control support via `GET_INFO`, exposes typed get/set per control with little-endian packing. `readTopology(locationID:)` is the static entry point used during connect.
- `Sources/LensBar/AVFoundationController.swift` — AVFoundation focus/exposure/format/fps control. `enumerateCameras()` lists every external + built-in video device for the picker. Opens an `AVCaptureSession` so the preview works and AVF state queries return live values.
- `Sources/LensBar/CameraController.swift` — combines the two paths for a chosen `AVCaptureDevice`. Parses the device's `uniqueID` into a USB location ID, reads the configuration descriptor, builds the IOKit controller from the discovered topology. IOKit failure is non-fatal — virtual cameras and non-UVC devices degrade to AVFoundation-only.
- `Sources/LensBar/CameraViewModel.swift` — `@MainActor` ObservableObject that drives the UI. Owns the camera picker (`availableDevices`, `selectedDeviceID` persisted in `UserDefaults`) and gates UVC slider loading on the per-control capability probe. Session lifetime goes through `CapturePipeline` demands (popover, virtual camera), not the popover alone; it also reopens the camera after unplug/replug. Owned by the app delegate, which calls `startVirtualCamera()` at launch.
- `Sources/LensBar/VirtualCamera*.swift`, `CMIOHardware.swift` — app side of LensBar Camera. `VirtualCameraMonitor` finds the CMIO device by UID and listens to its `lbcc` client count; `VirtualCameraDemandGate` turns the count into the `.virtualCamera` demand with a 5 s grace; `VirtualCameraSink` enqueues re-stamped frames from `FrameTap` on the sink stream; `VirtualCameraCoordinator` ties them together and pushes the format to `lbfm`.
- `Sources/LensBar/ExtensionInstaller.swift`, `ExtensionStatus.swift` — installs, upgrades and removes the LensBar Camera system extension with `OSSystemExtensionRequest`; the pure status / replace-on-upgrade / approval-pane logic is in `ExtensionStatus.swift` and tested. `LaunchAtLogin.swift` wraps `SMAppService.mainApp`. `VirtualCameraSection.swift` is the popover section for both. The app delegate owns the installer and `LaunchAtLogin` and injects them as environment objects.
- `Sources/LensBar/ContentView.swift` / `CameraPreview.swift` — SwiftUI views. `ContentView` is `public`. Shows a device picker when more than one camera is present.
- `LensBar/LensBar.xcodeproj` + `LensBar/LensBar/LensBarApp.swift` — Xcode app target. Owns the `@main App`, `MenuBarExtra` scene, and `AppDelegate` (sets `.accessory` activation). Imports `LensBarCore`. The Xcode target uses `PBXFileSystemSynchronizedRootGroup`, so any file added under `LensBar/LensBar/` is picked up automatically. App entitlements are in `LensBar/LensBar.entitlements` (`system-extension.install`).
- `LensBar/LensBarCamera/` — the `LensBarCamera` CoreMediaIO camera system extension ("LensBar Camera"), embedded in the app via *Embed System Extensions*. Sandboxed, links only `VirtualCameraKit`. One device with a source stream (clients read) and a sink stream (the app writes); forwards sink → source, shows a placeholder when the app isn't feeding it. Also a synchronized folder; `Info.plist` and the entitlements file are excluded from membership. See PLAN.md for the virtual-camera design.

## Key Constraints

- The UVC `CT_AE_MODE_CONTROL` must be set to manual (bitmap `0x01`) before `CT_EXPOSURE_TIME_ABSOLUTE_CONTROL` writes will take effect. `CameraViewModel.applyExposureMode` handles this when the auto-exposure toggle flips, and only when the control is supported.
- Exposure time is in **100µs units** per UVC spec (`1` = 0.1ms, `10000` = 1s).
- `iso`, `exposureDuration`, `lensPosition` are iOS-only AVFoundation properties — do not try to access them on macOS. Manual exposure/focus values must go through the UVC path instead.
- UVC unit IDs are **discovered at runtime** by parsing the configuration descriptor (USB `GET_DESCRIPTOR` for type=0x02). Do not hardcode them — they vary per camera vendor.
- AVCaptureDevice ↔ IOUSBHostDevice pairing uses the IOKit **location ID** parsed from `AVCaptureDevice.uniqueID`. Virtual cameras (OBS Virtual Cam, Continuity Camera, mmhmm) don't have a parseable location ID and silently fall back to AVF-only.
- The app sandbox is OFF (`ENABLE_APP_SANDBOX = NO`), so no extra entitlements are needed for `IOUSBHostDevice` access to arbitrary cameras. The camera extension is the opposite: it must be sandboxed and can't use IOKit, so all UVC control stays in the app.
- Debug builds sign automatically with Apple Development (pass `-allowProvisioningUpdates` to `xcodebuild`). Release signing is manual Developer ID with the two provisioning profiles described under Release Pipeline; a local Release archive needs both profiles installed under their default names (or `LENSBAR_APP_PROFILE=… LENSBAR_CAMERA_PROFILE=…`). For an unsigned compile check, pass `CODE_SIGNING_ALLOWED=NO`.
