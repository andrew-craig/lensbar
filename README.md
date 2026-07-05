# LensBar

A native macOS menu-bar app for controlling any standards-compliant **USB Video Class (UVC)** webcam — brightness, contrast, white balance, focus, exposure, zoom, and more, without opening a bloated vendor app.

LensBar lives in your menu bar. Click the icon, adjust sliders, done. Your settings are remembered per-camera and reapplied automatically the next time you launch.

## Why

Most webcam vendor apps are heavyweight, launch-at-login background processes that duplicate controls already exposed by the USB Video Class spec every camera implements. LensBar talks to the camera directly over two paths:

- **AVFoundation** — focus/exposure auto-vs-locked, format and frame-rate switching, and the live preview.
- **IOKit `IOUSBHostDevice`** — UVC Processing Unit and Camera Terminal controls (brightness, contrast, zoom, pan/tilt, absolute focus/exposure, etc.) sent as class-specific control transfers directly to the USB device.

The IOKit path is what makes fine-grained control possible at all: macOS's `UVCAssistant` daemon holds exclusive ownership of the camera's USB *interface*, which blocks typical libusb-style access. But the *device node* itself is not held by `UVCAssistant`, so EP0 class-specific requests sent at the device level (not the interface) go through without ever claiming an interface — no conflict with Photo Booth, Zoom, or anything else already using the camera.

LensBar was originally developed against the OBSBOT Meet SE but is fully camera-agnostic: unit IDs are discovered at runtime from the connected device's USB configuration descriptor, each control is probed for support before it's shown, and the UI simply hides anything the connected camera doesn't expose.

## Installation

### Homebrew (recommended)

```bash
brew install andrew-craig/tap/lensbar
```

### Manual download

Grab the latest signed, notarized DMG from the [Releases](https://github.com/andrew-craig/lensbar/releases) page:

- `LensBar.dmg` — arm64-only (Apple Silicon)
- `LensBar-universal.dmg` — arm64 + x86_64 (Intel Macs)

Open the DMG and drag `LensBar.app` to `/Applications`.

### Requirements

- macOS Sonoma (14) or later
- A UVC-compliant webcam (built-in FaceTime cameras and most external USB webcams qualify)

LensBar runs as a menu-bar-only ("accessory") app — it won't appear in the Dock or app switcher. Click the camera icon in the menu bar to open its control panel.

## Capabilities

### Device picker

If more than one camera is attached (including the built-in FaceTime camera), a picker at the top of the panel lets you switch between them. The last-selected camera is remembered across launches via `UserDefaults` and re-selected automatically if it's still plugged in.

### Live preview

A live `AVCaptureSession` preview is shown at the top of the panel so you can see the effect of every adjustment immediately. If another app already has the camera open, LensBar shows an "in use" placeholder instead of fighting for the stream — the UVC controls (see below) still work over EP0 even while another app owns the AVFoundation session.

### Format & frame rate (AVFoundation)

- **Format** — pick from the resolutions the active format list reports for the connected camera.
- **FPS** — pick from the frame rates supported by the currently selected format.

Both are read from and applied directly to the `AVCaptureDevice`.

### Focus

- **Auto Focus** toggle — switches between `continuousAutoFocus` and locked/manual focus (only shown if the device reports support).
- **Focus** slider (manual mode only) — drives `CT_FOCUS_ABSOLUTE_CONTROL` over the UVC Camera Terminal, with range discovered per-device via `GET_MIN`/`GET_MAX`.

### Exposure

- **Auto Exposure** toggle — switches the AVFoundation exposure mode and, for cameras that expose it, also writes `CT_AE_MODE_CONTROL` (manual `0x01` / auto `0x02`) over UVC. The UVC AE mode must be set to manual before exposure-time writes take effect — LensBar handles that ordering automatically.
- **Exposure** slider (manual mode only) — drives `CT_EXPOSURE_TIME_ABSOLUTE_CONTROL`, displayed in milliseconds (the UVC spec reports this control in 100µs units under the hood).

### Image adjustments (UVC Processing Unit)

Sliders are shown only for controls the connected camera actually supports (probed via `GET_INFO`):

| Control | UVC selector |
|---|---|
| Brightness | `PU_BRIGHTNESS_CONTROL` |
| Contrast | `PU_CONTRAST_CONTROL` |
| Hue | `PU_HUE_CONTROL` |
| Saturation | `PU_SATURATION_CONTROL` |
| Sharpness | `PU_SHARPNESS_CONTROL` |
| Gamma | `PU_GAMMA_CONTROL` |
| White Balance Temperature | `PU_WHITE_BALANCE_TEMPERATURE_CONTROL` |
| Backlight Compensation | `PU_BACKLIGHT_COMPENSATION_CONTROL` |
| Gain | `PU_GAIN_CONTROL` |

Each slider's range and default come straight from the camera (`GET_MIN`/`GET_MAX`/`GET_CUR`), so it always matches what the hardware actually accepts.

### White balance

- **Auto White Balance** toggle — drives `PU_WHITE_BALANCE_TEMPERATURE_AUTO_CONTROL`.
- **White Balance Temperature** slider (manual mode only) — sets the color temperature directly.

### Zoom

**Zoom** slider — drives `CT_ZOOM_ABSOLUTE_CONTROL` on cameras with optical or digital zoom, shown only when the camera reports a usable zoom range.

### Per-camera memory

Every adjustment is persisted to disk, keyed by device format/pixel-format identity, and replayed automatically the next time that specific camera connects — no need to re-dial in your settings after unplugging a camera or restarting the app.

## Architecture (for contributors)

The repo is split into a headless, testable Swift Package (`LensBarCore`) and a thin Xcode app target that wraps it in a `MenuBarExtra` scene. See `AGENTS.md` for the full internals: file layout, the UVC descriptor parser, the IOKit control transfer wrapper, and the release/notarization pipeline.

```bash
# Build & test the headless core
swift build
swift test

# Build the full .app bundle (must go through Xcode)
xcodebuild -project LensBar/LensBar.xcodeproj -scheme LensBar -configuration Release \
  -archivePath build/LensBar.xcarchive archive
```
