# PLAN: LensBar virtual camera

Status: Phase 0 spike done, decision **go** (2026-11-17). Phases 1 to 5 not started.
Written 2026-11-17; updated the same day with spike results (§6, Phase 0 results),
which changed the format-mirroring design (§4.5).

## 1. Problem

LensBar pins a UVC camera to 25 fps (mains-flicker avoidance) by writing
`activeVideoMinFrameDuration` on the physical `AVCaptureDevice`. On macOS that
setting is shared, system-wide device state, and any other process that opens
the camera renegotiates the stream and puts it back to the format default
(30 fps). Conferencing apps do this every time they (re)acquire the camera, so
the setting does not stick.

LensBar itself only re-asserts the rate while its popover is open
(`ContentView.onAppear → CameraViewModel.start()`, `CameraPreview.onAttach →
reapplyFrameRate()`), so nothing corrects the override afterwards.

## 2. Idea

Ship a **virtual camera** ("LensBar Camera"). Client apps select it instead of
the physical camera, so they never open, and never reconfigure, the physical
device. LensBar becomes the only client of the physical camera and holds it at
the format and frame rate set in LensBar (25 fps in the motivating case) for as
long as anything is consuming the virtual one.

The sensor must really run at 25 fps. Dropping frames from a 30 fps stream does
not remove flicker, so this is about protecting the physical device's
configuration, not about retiming frames.

## 3. Decisions (confirmed 2026-11-17)

- **LensBar must be running** for the virtual camera to deliver video. This is
  acceptable, so the app-captures design (4.3 A) is chosen.
- **The virtual camera mirrors LensBar's settings**: resolution and FPS follow
  whatever is selected in LensBar, and change when the user changes them.
- **No watchdog-only solution.** Re-asserting the frame rate on the physical
  camera after another app resets it has been tried and is not reliable enough.
  It is out of scope, both as an alternative and as a fallback.

## 4. Findings

### 4.1 The only supported mechanism is a CoreMediaIO Camera Extension

- `CMIOExtension` (macOS 12.3+) packaged as a **system extension** inside
  `LensBar.app/Contents/Library/SystemExtensions/`. Legacy DAL plug-ins are
  deprecated and are not loaded by current apps.
- The app's deployment target is already macOS 14, so there is no OS-version
  cost.
- The extension is installed with `OSSystemExtensionRequest`, needs one-time
  user approval in *System Settings → General → Login Items & Extensions →
  Camera Extensions*, and only activates when the app is in `/Applications`
  (the Homebrew cask already puts it there).

### 4.2 Constraints the extension brings

| Constraint | Consequence for LensBar |
|---|---|
| Extension **must be sandboxed** | It cannot use `IOUSBHostDevice`. All UVC control stays in the app. |
| Host app needs `com.apple.developer.system-extension.install`, a **restricted entitlement** | Requires provisioning profiles. Today the release is signed with a bare Developer ID certificate and no profile. This is the biggest pipeline change. |
| `CMIOExtensionMachServiceName` must sit under an app group the extension belongs to | New app group, e.g. `$(TeamIdentifierPrefix)com.andrewcraig.LensBar`; new entitlements files for both targets. |
| Developer ID system extensions must be notarized to load | Already done for the app; the nested extension is covered by the same submission. |
| Replacing an installed extension needs a version bump or an explicit `.replace` decision | Slower dev loop than `swift test`; needs a documented procedure. |

### 4.3 Who captures the physical camera

Two workable designs:

**A. App captures, pushes frames into the extension through a sink stream (recommended).**
The extension exposes one device with a *source* stream (what Zoom etc. read)
and a *sink* stream. The LensBar app runs the `AVCaptureSession` it already
has, adds an `AVCaptureVideoDataOutput`, and enqueues each frame on the sink
stream via the CoreMediaIO C API (`CMIOStreamCopyBufferQueue` +
`CMSimpleQueueEnqueue`). The extension forwards sink → source. This is the
pattern OBS uses and the one Apple DTS describes for getting video into an
extension.

- For: the app already has camera TCC permission, the capture code, the
  persisted settings and the unsandboxed UVC path. The extension stays tiny
  (about 300 lines, no camera access, no state).
- Against: the app must be running for the virtual camera to show video, and
  the app needs a signal for "a client started watching".

**B. Extension captures the physical camera itself.**
Reported to work on macOS 13+ (extension can request camera access), but there
is no authoritative Apple answer on TCC behaviour, the extension would need the
settings handed to it over custom properties, and debugging a sandboxed daemon
is slow.

- For: works with the app closed.
- Against: unverified permission model, duplicates the capture/restore logic in
  a second process, and UVC control still needs the app anyway.

**Chosen: A.** LensBar is a menu-bar app that is expected to be running, and
that requirement is accepted; launch-at-login closes the gap. B is not pursued.

### 4.4 Things in the current code that this touches

- `CameraViewModel.start()/stop()` are driven by popover visibility. The capture
  session has to outlive the popover: it must run when the popover is open
  **or** the virtual camera has clients.
- `AVFoundationController.openSession` documents that frame-duration writes are
  lost at `startRunning()` and again when a preview layer attaches. Adding a
  video data output is another reconfiguration point and will need the same
  re-assert at attach time. The data output also gives real frame timestamps,
  so LensBar can measure and display the true stream rate instead of trusting
  the property.
- `AVFoundationController.enumerateCameras()` uses `.externalUnknown`, which
  will list LensBar's own virtual camera. It must be filtered out, or LensBar
  could end up capturing itself.
- `NSCameraUsageDescription` still names the OBSBOT Meet SE; reword while
  touching the Info.plist keys.
- Local machine note: an OBSBOT Center camera extension is already registered
  here in state "activated waiting for user", so the approval UI and
  `systemextensionsctl list` are known to work on this Mac.

### 4.5 Format and frame-rate advertising

The source stream advertises exactly one format: the resolution set in
LensBar, with exactly one frame rate, the FPS set in LensBar
(`minFrameDuration == maxFrameDuration`, single entry in
`validFrameDurations`). Clients then have nothing else to select.

**Changing it while clients are streaming (revised after spike step 5).** Apple's
header says a stream's `formats` "should not change during the life cycle of the
associated stream", and Zoom confirms it. Replacing the streams live left Zoom
frozen on the last frame, and toggling video didn't recover it. Replacing the
whole device made Zoom switch its video off. Pushing frames at the new
resolution or frame rate under the *unchanged* advertised format worked: Zoom
followed both a 25 → 30 fps change and a 720p → 1080p change without any
disruption. So:

- **Clients streaming (client count > 0):** keep the advertised format and push
  frames at the new size and rate. The picture and the real frame rate follow
  LensBar; only the advertised metadata lags behind.
- **No clients (client count = 0):** update the advertised format by replacing
  the device (same device ID), so the next client gets the correct descriptor.
  If the user changes settings mid-call, apply the deferred update as soon as
  the count reaches 0.
- Never call `removeStream`/`addStream` on a live device. A removed stream ID
  can't be re-added to the same device, and a device left with no streams
  disappears from the system.

Only Zoom has been tested. Another client could reject frames that don't match
the advertised format, which is a Phase 6 check.

## 5. Target architecture (design A)

```
 physical UVC camera
        │  AVCaptureSession (LensBar's format + FPS, LensBar is sole client)
        ▼
 LensBar.app (unsandboxed, menu bar)
   ├─ CapturePipeline      session lifetime = popover open OR virtual-cam clients > 0
   ├─ FrameTap             AVCaptureVideoDataOutput → CMSampleBuffer (NV12, IOSurface-backed)
   ├─ RateMonitor          measures real frame interval for display and verification
   ├─ VirtualCameraSink    CMIO C API: find device by UID, start sink stream, enqueue
   ├─ ExtensionInstaller   OSSystemExtensionRequest activate / deactivate / status
   └─ IOKit UVC controls   unchanged
        │  sink stream
        ▼
 LensBarCamera.systemextension (sandboxed CMIOExtension)
   ├─ one device "LensBar Camera", fixed UID
   ├─ sink stream  → forwards to source stream
   ├─ source stream, one format + one frame rate, mirrored from LensBar
   ├─ custom property: client count (source start/stop), read by the app
   └─ placeholder frame when no sink data ("Open LensBar")
        │
        ▼
 Zoom / Meet / Teams / FaceTime select "LensBar Camera"
```

Code placement:

- New SwiftPM target `VirtualCameraKit` (no IOKit dependency, safe for the
  sandboxed extension): device/stream UIDs, custom property names, the
  format-descriptor codec (resolution, pixel format, FPS), the rate estimator. Unit-tested with `swift test`.
- `LensBarCore` gains `CapturePipeline`, `FrameTap`, `RateMonitor`,
  `VirtualCameraSink`, `ExtensionInstaller`, and the UI section.
- New Xcode target `LensBarCamera` under `LensBar/LensBarCamera/`, embedded in
  the app's *Embed System Extensions* phase. Create it with Xcode's Camera
  Extension template rather than hand-editing `project.pbxproj`.

## 6. Work plan

### Phase 0: spike (throwaway code, decides whether to continue)

1. Build a standalone `swiftc` harness (per the `run-app` skill) that holds the
   camera at 25 fps with a video data output and logs the measured frame
   interval. Use it as the oracle for everything below.
2. Create the Xcode template camera extension in a scratch project, sign with
   the development team, activate it on this Mac.
3. Feed it from the harness through a sink stream. Select the virtual camera in
   each target app and exercise the join / leave / mute-video / re-trigger
   paths that currently break the rate.
4. Confirm with the harness log that the physical stream stays at 25 fps
   throughout, and that no target app opens the physical camera in the
   background while the virtual one is selected.
5. Change the advertised format and frame rate while a client is streaming and
   confirm the client follows without needing to reselect the camera.
6. Check that the app can read the extension's client-count property, and
   whether property-change notifications arrive or polling is needed.

Exit criteria: physical rate holds at 25 fps across every re-trigger scenario
with no corrective re-assertion needed; added latency is about one frame;
activation works from a signed build.

#### Phase 0 results (2026-11-17, OBSBOT Meet SE, Zoom; decision: go)

Spike code lives in `spike/` (harness, property tool, XcodeGen camera-extension
project) and is throwaway. Full notes are in the closed chalk tasks.

- **Rate holds:** met for Zoom. With Zoom set to the virtual camera, the physical
  camera stayed at 25.00 fps through join, video toggle, camera switch and back,
  leave and rejoin, the Settings → Video preview, and quitting and relaunching
  Zoom. Nothing re-asserted the rate. The only reset seen came from selecting
  the physical camera directly in Zoom, or from Zoom previewing it before the
  user switched cameras.
- **Latency:** about 5 ms from sink enqueue to client, against a 40 ms frame.
  No sink drops.
- **Activation:** works with Apple Development signing and automatic profiles
  (this Mac had to be registered in the developer account). Approval took the
  (i) → toggle → password path in Login Items & Extensions; the first attempt
  didn't stick. Upgrading needs only a higher `CFBundleVersion` and the
  `.replace` delegate answer, with no re-approval, and Zoom recovers from the
  extension restart by itself. **Developer ID + notarized activation is still
  unproven** and remains the Phase 5 risk.
- **Client count:** a custom device property (`4cc_lbcc_glob_0000`, String) plus
  `notifyPropertiesChanged` reaches a `CMIOObjectAddPropertyListenerBlock`
  in about 40 ms, so polling isn't needed. It needs no camera permission or
  entitlement on the app side. The CMIO device object ID can change, so look
  it up by UID and re-add listeners when `kCMIOHardwarePropertyDevices` changes.
- **Sink feed from the app:** `CMIOStreamCopyBufferQueue` + `CMIODeviceStartStream`
  + `CMSimpleQueueEnqueue` works from an unsandboxed, unsigned process. The sink
  stream is the one with `kCMIOStreamPropertyDirection == 0`. CMIO reports a
  queue capacity of 10.
- **Format changes:** see §4.5. Live stream or device replacement disrupts Zoom;
  pushing frames under a fixed format works.
- **Signals that don't work:** `AVCaptureDevice.isInUseByAnotherApplication`
  stayed false even while Zoom streamed the physical camera directly. Detect
  resets via KVO on `activeVideoMinFrameDuration` and the measured rate.
- **Client behaviour:** Zoom starts and stops the source stream on every video
  toggle and camera switch (about six sessions in two minutes), so the
  demand grace period matters.
- **Camera permission:** it's attributed to the responsible process. A
  terminal-launched harness only works from a terminal that has camera access.
- **Oddity:** the OBSBOT dropped off USB once during rapid capture restarts and
  had to be replugged. Cause unknown; watch for it.

### Phase 1: capture pipeline refactor (no extension yet)

- Split session lifetime from popover lifetime in `CameraViewModel` /
  `CameraController`; introduce `CapturePipeline` with explicit demand sources
  (popover, virtual camera).
- Add `FrameTap` and re-assert FPS after the output is attached.
- Add `RateMonitor` driven by real presentation timestamps; surface "actual
  fps" in the popover. It reports only, it does not correct.
- Filter LensBar's own device out of `enumerateCameras()`.
- Tests: rate estimator, demand state machine, device filtering.

This phase is useful on its own and carries no signing risk.

### Phase 2: extension target

- Add `VirtualCameraKit` to `Package.swift`.
- Add the `LensBarCamera` system-extension target: provider, device, source and
  sink streams, a single NV12 format whose resolution and frame rate are set by
  the app from LensBar's current settings (the last pushed descriptor is
  remembered for when the app is not running, and applied by device replacement
  only at zero clients, per §4.5), client-count property with
  `notifyPropertiesChanged`, placeholder frame generator. Fresh stream IDs
  whenever streams are rebuilt.
- Entitlements: extension gets app sandbox + app group; app gets
  `system-extension.install` (and stays unsandboxed).
- Make sure the universal build (`ARCHS="arm64 x86_64"`) covers the extension.

### Phase 3: app ↔ extension plumbing

- `VirtualCameraSink`: locate the device by UID, start the sink stream, enqueue
  frames re-stamped on the host clock, handle queue-full by dropping.
- Demand-driven lifecycle: client count > 0 starts the pipeline, 0 stops it
  after a short grace period so quick re-triggers do not restart the camera.
- Mirroring (per revised §4.5): when the user changes resolution or FPS in
  LensBar (`applyFormat` / `applyFPS`), reconfigure the physical camera and keep
  enqueuing; frames at the new size and rate flow through the unchanged
  advertised format. Push the new descriptor to the extension
  (custom property), which applies it by replacing the device only when its
  client count is 0, either straight away or deferred until the count reaches 0.
- Handle camera unplug / replug and app relaunch while a client is streaming.

### Phase 4: install flow and UI

- "Virtual camera" section in `ContentView`: Install / needs approval (deep
  link to the settings pane) / active / Remove, plus client count and actual
  fps.
- `ExtensionInstaller` with the request delegate, including the
  replace-on-upgrade decision.
- Launch at login via `SMAppService.mainApp`, offered when the virtual camera
  is enabled.
- Reword `NSCameraUsageDescription`.
- Guidance in the section: "select LensBar Camera in your call app before it
  previews your webcam", and walk through the approval path in Login Items &
  Extensions → Camera Extensions → (i).

### Phase 5: signing, release, CI, docs

- Create two Developer ID provisioning profiles (app, extension) with the
  system-extension capability; add them as base64 secrets.
- `release.yml`: install profiles in both build jobs; pass per-target
  `PROVISIONING_PROFILE_SPECIFIER`; add the `provisioningProfiles` map to
  `ExportOptions.plist`; verify with `codesign -d --entitlements` and
  `spctl` before notarizing.
- `ci.yml`: add an unsigned `xcodebuild build` job (`CODE_SIGNING_ALLOWED=NO`)
  so extension compile breaks are caught on PRs; today only `swift test` runs.
- Cask: add an uninstall note / `caveats`, because removing the app with
  `brew uninstall` may leave the extension registered; the in-app Remove button
  is the supported path.
- Update `CLAUDE.md`, `README.md` and the `run-app` skill (activation,
  `systemextensionsctl list`, log predicates for the extension, how to replace
  an installed build).

### Phase 6: verification matrix

Each target app × {join, leave, toggle video, switch camera away and back,
sleep/wake, unplug/replug, LensBar quit and relaunch mid-call, popover
open/closed, change resolution and FPS in LensBar mid-call}. Pass = measured
physical rate stays at the LensBar-set FPS, the virtual camera reports the same
format and FPS, and it recovers without the client needing to reselect it.

## 7. Risks

| Risk | Mitigation |
|---|---|
| A target app still opens the physical camera in the background (probing all devices) and resets it | Not seen with Zoom (spike). No reliable mitigation exists (re-asserting is the rejected watchdog); an app that does this is a known limitation, surfaced by the "actual fps" readout. |
| The physical camera was reset before the user switched the client to LensBar Camera (e.g. Zoom previewing the physical camera first) | Seen in the spike. Install UI and README tell the user to select LensBar Camera first; the "actual fps" readout shows when the rate has been lost; reopening the pipeline re-applies the format (a fresh start, not a watchdog). |
| A client mishandles a format change mid-stream | Confirmed for Zoom with stream/device replacement. Avoided by the revised §4.5: the advertised format changes only with zero clients. Residual risk: another client rejects frames that don't match the advertised format (Phase 6). |
| Profile-based signing breaks the release pipeline | Do Phase 5 on a pre-release tag via `workflow_dispatch` before merging user-facing UI. |
| Client-count notifications unreliable | Spike: listeners fire in about 40 ms. Keep a slow (about 5 s) poll as a safety net only. |
| User friction: approval step, extra camera in every picker | Feature is opt-in; nothing is installed until the user clicks Install. |
| Browsers and some apps cache the device list | Document "restart the app after installing"; known camera-extension behaviour. |
| App not running → black virtual camera | Placeholder frame plus launch-at-login. |
| Dev loop cost (must run from `/Applications`, version bumps) | Keep logic in `VirtualCameraKit` / `LensBarCore` under `swift test`; extension stays thin. |

## 8. Open questions

1. ~~Which apps cause the override today?~~ Answered: Zoom (desktop) is the
   test matrix for Phase 0 and Phase 6.
2. Does a notarized Developer ID build activate the extension the same way the
   development-signed spike did? This is answered by the Phase 5 pre-release run.

## 9. Rough size

Phase 0 is a day or two and decides everything. Phases 1 to 4 are the bulk of
the code (a few focused PRs). Phase 5 is small in lines but is the part most
likely to need iteration, because it can only be validated by running the
release workflow.

## 10. References

- Apple Developer Forums, DTS on sink streams: https://developer.apple.com/forums/thread/708550
- Hardware camera access from inside a camera extension (unanswered by Apple; macOS 13+ reports): https://developer.apple.com/forums/thread/708293
- Detecting whether the extension is in use (custom property approach): https://developer.apple.com/forums/thread/709204
- Frame-rate formats and `validFrameDurations`: https://developer.apple.com/forums/thread/812036
- Restricted `system-extension.install` entitlement and profiles: https://developer.apple.com/forums/thread/793731
- Signature / entitlement failures on activation: https://developer.apple.com/forums/thread/736838
- Sample sink-stream camera extension: https://github.com/ldenoue/cameraextension
