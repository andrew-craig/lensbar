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

Pushing a `v*` tag (or a manual `workflow_dispatch` with a `tag` input) runs `.github/workflows/release.yml`, which builds two signed, notarized, stapled DMGs in parallel — `LensBar.dmg` (arm64-only, `macos-26`) and `LensBar-universal.dmg` (arm64+x86_64, `macos-14`, needed because the universal slice can't be built on the newer runner) — attaches both to a GitHub Release, then renders `Casks/lensbar.rb.tmpl` (substituting version + both DMG checksums) and pushes the result as `Casks/lensbar.rb` to the `andrew-craig/homebrew-tap` repo via a `HOMEBREW_TAP_TOKEN` PAT secret. The published cask uses `on_arm`/`on_intel` to pick the right DMG per architecture. Users install with `brew install andrew-craig/tap/lensbar`.

## Layout

- `Package.swift` — two targets: `IOKitUSB` (ObjC, links `IOUSBHost` + `IOKit`) and `LensBarCore` (Swift library with the headless camera control + SwiftUI views). No `@main` lives in the package.
- `Sources/IOKitUSB/UVCDeviceController.{h,m}` — thin ObjC wrapper around `IOUSBHostDevice`. Sends UVC class-specific GET/SET requests on EP0, plus standard `GET_DESCRIPTOR` for runtime topology discovery. Kept in ObjC so Swift doesn't need an unsafe bridging header for IOUSBHost. Opens by USB location ID so it can pair with an arbitrary `AVCaptureDevice` (a VID/PID initializer remains for tests).
- `Sources/LensBar/UVCTypes.swift` — UVC request codes, `PUControl` / `CTControl` selectors, `AEMode` bitmap values. All standard UVC 1.5 — no device-specific identity.
- `Sources/LensBar/UVCDescriptorParser.swift` — pure-Swift TLV walker over a USB configuration descriptor. Extracts the VideoControl interface number, Camera Terminal ID (input terminal with `wTerminalType=0x0201`), and Processing Unit ID. Either unit may be nil; the UI degrades accordingly.
- `Sources/LensBar/IOKitUVCController.swift` — Swift façade over `UVCDeviceController`. Takes a discovered `UVCTopology` at init, probes per-control support via `GET_INFO`, exposes typed get/set per control with little-endian packing. `readTopology(locationID:)` is the static entry point used during connect.
- `Sources/LensBar/AVFoundationController.swift` — AVFoundation focus/exposure/format/fps control. `enumerateCameras()` lists every external + built-in video device for the picker. Opens an `AVCaptureSession` so the preview works and AVF state queries return live values.
- `Sources/LensBar/CameraController.swift` — combines the two paths for a chosen `AVCaptureDevice`. Parses the device's `uniqueID` into a USB location ID, reads the configuration descriptor, builds the IOKit controller from the discovered topology. IOKit failure is non-fatal — virtual cameras and non-UVC devices degrade to AVFoundation-only.
- `Sources/LensBar/CameraViewModel.swift` — `@MainActor` ObservableObject that drives the UI. Owns the camera picker (`availableDevices`, `selectedDeviceID` persisted in `UserDefaults`) and gates UVC slider loading on the per-control capability probe.
- `Sources/LensBar/ContentView.swift` / `CameraPreview.swift` — SwiftUI views. `ContentView` is `public`. Shows a device picker when more than one camera is present.
- `LensBar/LensBar.xcodeproj` + `LensBar/LensBar/LensBarApp.swift` — Xcode app target. Owns the `@main App`, `MenuBarExtra` scene, and `AppDelegate` (sets `.accessory` activation). Imports `LensBarCore`. The Xcode target uses `PBXFileSystemSynchronizedRootGroup`, so any file added under `LensBar/LensBar/` is picked up automatically.

## Key Constraints

- The UVC `CT_AE_MODE_CONTROL` must be set to manual (bitmap `0x01`) before `CT_EXPOSURE_TIME_ABSOLUTE_CONTROL` writes will take effect. `CameraViewModel.applyExposureMode` handles this when the auto-exposure toggle flips, and only when the control is supported.
- Exposure time is in **100µs units** per UVC spec (`1` = 0.1ms, `10000` = 1s).
- `iso`, `exposureDuration`, `lensPosition` are iOS-only AVFoundation properties — do not try to access them on macOS. Manual exposure/focus values must go through the UVC path instead.
- UVC unit IDs are **discovered at runtime** by parsing the configuration descriptor (USB `GET_DESCRIPTOR` for type=0x02). Do not hardcode them — they vary per camera vendor.
- AVCaptureDevice ↔ IOUSBHostDevice pairing uses the IOKit **location ID** parsed from `AVCaptureDevice.uniqueID`. Virtual cameras (OBS Virtual Cam, Continuity Camera, mmhmm) don't have a parseable location ID and silently fall back to AVF-only.
- The app sandbox is OFF (`ENABLE_APP_SANDBOX = NO`), so no extra entitlements are needed for `IOUSBHostDevice` access to arbitrary cameras.
