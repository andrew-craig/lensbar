# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

A native macOS menu-bar app (Swift Package at the repo root) that controls an **OBSBOT Meet SE** webcam. Two control paths are combined:

- **AVFoundation** — focus/exposure auto-or-locked, format and frame-rate switching.
- **IOKit `IOUSBHostDevice`** — UVC Processing Unit, Camera Terminal, and proprietary Extension Unit controls via EP0 control transfers.

The IOKit path is what makes this app possible. macOS's `UVCAssistant` daemon holds exclusive ownership of `IOUSBHostInterface@0`, which blocks libusb-style access. But the *device node* (`IOUSBHostDevice`) is not held by `UVCAssistant`, so EP0 class-specific requests sent at the device level (not the interface) go through without claiming any interface.

## Building and Running

```bash
swift build
swift run LensBar
```

## Layout

- `Package.swift` — two targets: `IOKitUSB` (ObjC, links `IOUSBHost` + `IOKit`) and `LensBar` (Swift executable, SwiftUI menu-bar UI).
- `Sources/IOKitUSB/UVCDeviceController.{h,m}` — thin ObjC wrapper around `IOUSBHostDevice` that sends UVC class-specific GET/SET requests on EP0. Kept in ObjC so Swift doesn't need an unsafe bridging header for IOUSBHost.
- `Sources/LensBar/UVCTypes.swift` — `OBSBOT` constants (VID/PID, unit IDs), UVC request codes, `PUControl` / `CTControl` selectors, `AEMode` bitmap values.
- `Sources/LensBar/IOKitUVCController.swift` — Swift façade over `UVCDeviceController`; typed get/set per control with little-endian packing.
- `Sources/LensBar/AVFoundationController.swift` — AVFoundation focus/exposure/format/fps control. Opens an `AVCaptureSession` so the preview works and AVF state queries return live values.
- `Sources/LensBar/CameraController.swift` — combines the two paths; IOKit failure is non-fatal.
- `Sources/LensBar/CameraViewModel.swift` — `@MainActor` ObservableObject that drives the UI.
- `Sources/LensBar/ContentView.swift` / `LensBarApp.swift` / `CameraPreview.swift` — SwiftUI views and menu-bar setup.

## Key Constraints

- The UVC `CT_AE_MODE_CONTROL` must be set to manual (bitmap `0x01`) before `CT_EXPOSURE_TIME_ABSOLUTE_CONTROL` writes will take effect. `CameraViewModel.applyExposureMode` handles this when the auto-exposure toggle flips.
- Exposure time is in **100µs units** per UVC spec (`1` = 0.1ms, `10000` = 1s).
- `iso`, `exposureDuration`, `lensPosition` are iOS-only AVFoundation properties — do not try to access them on macOS. Manual exposure/focus values must go through the UVC path instead.
- The proprietary Extension Unit (`unitID=2`, GUID `{9a1e7291-6843-4683-6d92-39bc7906ee49}`) has 7 controls; they're readable/writable but their semantics are undocumented (presumed OBSBOT AI tracking, gesture, zoom assist).

## Device Identity

- Name: `OBSBOT Meet SE` (matched by `localizedName.contains` in `AVFoundationController.findOBSBOT`)
- VID/PID: `0x3564` / `0xFEFE`
- UVC unit IDs: Camera Terminal = 1, Extension Unit = 2, Processing Unit = 3, VideoControl interface = 0
