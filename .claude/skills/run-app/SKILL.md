---
name: run-app
description: Build, launch, and verify the LensBar macOS menu-bar app against a real camera. Use when asked to run the app, reproduce a UI/camera bug, confirm a fix works in the actual app (not just `swift test`), or inspect its runtime logs. Covers the Xcode build path, launching the menu-bar app, reading os_log output, and the camera-FPS gotchas verified during debugging.
---

# Running and verifying LensBar

LensBar is a **native macOS menu-bar app** (`MenuBarExtra`, `.accessory` activation).
There is **no main window** — the UI is a popover that appears only when its menu-bar
icon is clicked. The headless core (`LensBarCore`) builds with SwiftPM, but anything
involving the app bundle, entitlements, codesigning, the preview layer, or live camera
behavior **must go through the Xcode build**. `swift run` does not exist here.

## Fast loop (logic only — no camera, no UI)

```bash
swift build      # compile LensBarCore
swift test       # 100+ unit tests: UVC parsing, demand gate, format codec, extension status, …
```

Use this for pure-logic changes (UVC parsing, snapshot codec, etc.). It cannot exercise
AVFoundation capture, the preview layer, or `MenuBarExtra` — those need the real app.

## Build & launch the real app

```bash
# Quit any running instance first (otherwise you'll inspect a stale build)
pkill -f "LensBar.app/Contents/MacOS/LensBar"

# Debug build into a local derivedData dir (keeps it out of the default DerivedData)
xcodebuild -project LensBar/LensBar.xcodeproj -scheme LensBar \
  -configuration Debug -derivedDataPath build/dd build

# Launch — it appears in the menu bar, NOT as a window
open build/dd/Build/Products/Debug/LensBar.app

# Confirm it's running
pgrep -lf "LensBar.app/Contents/MacOS/LensBar"
```

For a release archive (signing/notarization path), use the `archive` action from
`CLAUDE.md` instead.

## Driving it — you cannot click the menu bar programmatically

There is no headless way to open the popover or move a slider here. The app only does
real work (`ContentView.onAppear → CameraViewModel.start()`) **once the popover is
opened**. So to verify camera/UI behavior:

1. Build + launch (above).
2. **Ask the user to interact**: open the menu-bar icon, change the control under test,
   close/reopen the popover (closing fires `onDisappear → stop()`, reopening re-runs the
   full `start()` pipeline — this is the relaunch/restore path).
3. Read the logs (below) to confirm what actually happened.

A visual oracle the user can give you: mains-flicker tells them whether the stream is
truly at 25 fps. Use that to distinguish "the displayed value is right" from "the real
camera rate is right" — they are not the same thing (see gotchas).

## Reading runtime logs

The app logs via `os.Logger(subsystem: "com.lensbar")`. **`log` is shadowed by a shell
alias in this environment — always use the absolute path `/usr/bin/log`.**

```bash
# Recent logs (camera connect, topology, control probe)
/usr/bin/log show --last 5m --info --predicate 'subsystem == "com.lensbar"'

# Filter to one category
/usr/bin/log show --last 5m --info \
  --predicate 'subsystem == "com.lensbar" AND category == "camera"'
```

Two subsystems are in use:

- `com.lensbar`: `camera` (CameraController: openSession, topology, busy state),
  `uvc` (control-support probe summary), and `extension` (the LensBar Camera
  extension itself: client count, format changes, sink/placeholder switching).
- `com.andrewcraig.LensBar`: `Camera` (CameraViewModel), `VirtualCamera`
  (monitor + coordinator: device lookup, `lbcc` count, `lbfm` pushes, demand),
  `VirtualCameraSink` (attach/detach, queue-full drops), `ExtensionInstaller`
  (sysextd requests and results), `LaunchAtLogin`.

```bash
# Everything virtual-camera related, app and extension
/usr/bin/log show --last 10m --info --predicate \
  'subsystem == "com.andrewcraig.LensBar" OR (subsystem == "com.lensbar" AND category == "extension")'

# The extension runs as a separate process (owned by _cmiodalassistants), so
# filter by process too when the subsystem isn't enough
/usr/bin/log stream --info --predicate 'process == "com.andrewcraig.LensBar.Camera"'

# Activation / approval problems are logged by the system, not by LensBar
/usr/bin/log show --last 10m --predicate 'process == "sysextd"'
```

### Temporary diagnostics

When a value needs tracing through the live pipeline, add a throwaway logger and reproduce:

```swift
import os
private let dbg = Logger(subsystem: "com.lensbar", category: "fpsdebug")
// dbg.info("openSession post-start currentFPS=\(self.currentFPS, format: .fixed(precision: 2))")
```

Rebuild, launch, have the user reproduce once, then
`/usr/bin/log show --predicate 'category == "fpsdebug"'`. **Remove the instrumentation
before finishing.**

### Standalone AVFoundation harness

The terminal already holds camera TCC permission (`AVCaptureDevice.authorizationStatus`
returns authorized), so you can compile a tiny `swiftc` program that opens the OBSBOT
directly and measures real frame delivery via `AVCaptureVideoDataOutput` — invaluable for
isolating "does the camera/AVFoundation do X" from "does the app's orchestration do X".
Match the app's conditions (e.g. attach an `AVCaptureVideoPreviewLayer` to the running
session) or the harness will pass while the app fails.

## LensBar Camera (system extension)

The virtual camera is a CoreMediaIO system extension embedded in the app
(`Contents/Library/SystemExtensions/com.andrewcraig.LensBar.Camera.systemextension`).
Everything about it — install, approval, upgrade — goes through `sysextd`, and
the user has to approve it, so plan for the user to click and type their password.

- **Activation needs the app in `/Applications`.** Copy the Debug build there
  (`ditto build/dd/Build/Products/Debug/LensBar.app /Applications/LensBar.app`)
  and launch that copy. From anywhere else Install fails with
  `unsupportedParentBundleLocation` unless `systemextensionsctl developer on`
  (needs SIP off) is set.
- **Approval:** after Install, the user goes to System Settings → General →
  Login Items & Extensions → Camera Extensions → (i) and toggles LensBar Camera
  on (macOS 15+; macOS 14: Privacy & Security). In the spike the first attempt
  didn't always stick; retry the toggle.
- **State:** `systemextensionsctl list` shows the team ID, bundle ID, version
  and state (`[activated enabled]`, `[activated waiting for user]`,
  `[terminated waiting to uninstall on reboot]`).
- **Replacing an installed build:** Debug builds always answer `.replace`
  (their version never changes), so relaunching a new Debug copy from
  `/Applications` upgrades the extension without re-approval. Release builds
  replace only when `CFBundleShortVersionString` / `CFBundleVersion` differ
  (CI uses the run number). Replacing restarts the extension, which cuts live
  calls briefly; Zoom recovers by itself.
- **Removing:** use **Remove LensBar Camera…** in the app.
  `systemextensionsctl uninstall B8A6HLKG3J com.andrewcraig.LensBar.Camera`
  only works with SIP off. An old `com.andrewcraig.LensBarSpike.Camera` from
  the Phase 0 spike may still be listed and show up as a second virtual camera.
- **Client apps cache the device list:** restart Zoom/browsers after installing.
- **Checking a build's signing:**
  `scripts/verify-signing.sh build/dd/Build/Products/Debug/LensBar.app codesign arm64`
  (the release workflow runs the stricter `pre-notarize` / `post-staple` stages).

## Camera-behavior gotchas (hard-won)

- **Property ≠ real stream rate.** `device.activeVideoMinFrameDuration` (what `currentFPS`
  and the FPS picker read) can hold a value the UVC stream never actually adopted. Always
  confirm the *real* rate (flicker, or a frame-counting harness), not just the property.
- **Frame-duration writes before `startRunning()` are discarded** — `startRunning`
  renegotiates the UVC stream at the format default. Apply FPS on the *running* session.
- **Attaching `AVCaptureVideoPreviewLayer.session` to a running session synchronously
  resets the device frame duration to the format default.** This silently undoes a
  restored FPS. The fix re-asserts the rate right after the preview attaches
  (`CameraPreview.onAttach → CameraViewModel.reapplyFrameRate`).
- The OBSBOT Meet SE exposes **discrete** frame rates per format (e.g. 1280×720: 15/25/30/
  60/120/150). `setFPS` snaps to the nearest within 1.0 fps or throws.
- `iso`/`exposureDuration`/`lensPosition` are iOS-only — never accessed on macOS; manual
  exposure/focus go through the UVC (IOKit) path instead.
