# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A native macOS menu-bar app that controls an **OBSBOT Meet SE** webcam. The repo is split into a Swift Package providing the headless, testable core (`LensBarCore`) and an Xcode project (`LensBar/LensBar.xcodeproj`) that builds the `.app` bundle around it. Two control paths are combined:

- **AVFoundation** — focus/exposure auto-or-locked, format and frame-rate switching.
- **IOKit `IOUSBHostDevice`** — UVC Processing Unit, Camera Terminal, and proprietary Extension Unit controls via EP0 control transfers.

The IOKit path is what makes this app possible. macOS's `UVCAssistant` daemon holds exclusive ownership of `IOUSBHostInterface@0`, which blocks libusb-style access. But the *device node* (`IOUSBHostDevice`) is not held by `UVCAssistant`, so EP0 class-specific requests sent at the device level (not the interface) go through without claiming any interface.

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

## Layout

- `Package.swift` — two targets: `IOKitUSB` (ObjC, links `IOUSBHost` + `IOKit`) and `LensBarCore` (Swift library with the headless camera control + SwiftUI views). No `@main` lives in the package.
- `Sources/IOKitUSB/UVCDeviceController.{h,m}` — thin ObjC wrapper around `IOUSBHostDevice` that sends UVC class-specific GET/SET requests on EP0. Kept in ObjC so Swift doesn't need an unsafe bridging header for IOUSBHost.
- `Sources/LensBar/UVCTypes.swift` — `OBSBOT` constants (VID/PID, unit IDs), UVC request codes, `PUControl` / `CTControl` selectors, `AEMode` bitmap values.
- `Sources/LensBar/IOKitUVCController.swift` — Swift façade over `UVCDeviceController`; typed get/set per control with little-endian packing.
- `Sources/LensBar/AVFoundationController.swift` — AVFoundation focus/exposure/format/fps control. Opens an `AVCaptureSession` so the preview works and AVF state queries return live values.
- `Sources/LensBar/CameraController.swift` — combines the two paths; IOKit failure is non-fatal.
- `Sources/LensBar/CameraViewModel.swift` — `@MainActor` ObservableObject that drives the UI. `public`.
- `Sources/LensBar/ContentView.swift` / `CameraPreview.swift` — SwiftUI views. `ContentView` is `public`.
- `LensBar/LensBar.xcodeproj` + `LensBar/LensBar/LensBarApp.swift` — Xcode app target. Owns the `@main App`, `MenuBarExtra` scene, and `AppDelegate` (sets `.accessory` activation). Imports `LensBarCore`. The Xcode target uses `PBXFileSystemSynchronizedRootGroup`, so any file added under `LensBar/LensBar/` is picked up automatically.

## Key Constraints

- The UVC `CT_AE_MODE_CONTROL` must be set to manual (bitmap `0x01`) before `CT_EXPOSURE_TIME_ABSOLUTE_CONTROL` writes will take effect. `CameraViewModel.applyExposureMode` handles this when the auto-exposure toggle flips.
- Exposure time is in **100µs units** per UVC spec (`1` = 0.1ms, `10000` = 1s).
- `iso`, `exposureDuration`, `lensPosition` are iOS-only AVFoundation properties — do not try to access them on macOS. Manual exposure/focus values must go through the UVC path instead.
- The proprietary Extension Unit (`unitID=2`, GUID `{9a1e7291-6843-4683-6d92-39bc7906ee49}`) has 7 controls; they're readable/writable but their semantics are undocumented (presumed OBSBOT AI tracking, gesture, zoom assist).

## Device Identity

- Name: `OBSBOT Meet SE` (matched by `localizedName.contains` in `AVFoundationController.findOBSBOT`)
- VID/PID: `0x3564` / `0xFEFE`
- UVC unit IDs: Camera Terminal = 1, Extension Unit = 2, Processing Unit = 3, VideoControl interface = 0
