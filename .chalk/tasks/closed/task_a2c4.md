---
id: task_a2c4
title: Spike: feed the extension from the harness via a sink stream and exercise re-triggers
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-0,spike]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T00:33:24Z
---
PLAN.md §6 Phase 0 steps 3-4. Enqueue harness frames on the sink stream (CMIOStreamCopyBufferQueue + CMSimpleQueueEnqueue), extension forwards sink→source. In each target app: join/leave/mute video/re-trigger. Confirm via harness log the physical stream stays at 25 fps with no corrective re-assertion, that no app opens the physical camera in the background, and latency is ~1 frame.

## Result (2026-11-17) — PASS
Harness gained `--sink <device UID>` (`spike/harness/Sink.swift`): finds the CMIO device by
UID, picks the stream with kCMIOStreamPropertyDirection == 0 (sink; source reports 1),
CMIOStreamCopyBufferQueue + CMIODeviceStartStream, re-stamps each frame on the host clock
(CMSampleBufferCreateCopyWithNewTiming) and CMSimpleQueueEnqueue; drops if full. Queue
capacity reported by CMIO: 10. Works from an unsandboxed, unsigned CLI process.

Measurements (OBSBOT Meet SE 1280x720 420v @25):
- Reader on "LensBarSpike Camera": 25.00 fps, max gap ~42 ms, added latency enqueue→client
  ~5 ms (well under one frame). Zero sink drops over all runs.
- Zoom run 2 (`build/spike-zoom-run2.log`), Zoom already set to LensBarSpike: join, video
  off/on, switch to MacBook camera and back, leave/rejoin, Settings → Video, quit and relaunch
  Zoom → physical camera stayed at 25.00 fps throughout, no KVO change, no corrective
  re-assertion (harness never re-asserts). Video looked normal to the user.
- Control: selecting "OBSBOT Meet SE" directly in Zoom reset the physical camera 25 → 30
  (KVO at 11:31:52.9); switching back to LensBarSpike did not restore 25 (expected — nothing
  re-asserts). Confirms the oracle detects Zoom's reset.
- Run 1 was invalid as a test: Zoom launched with the OBSBOT still selected and its
  Settings → Video preview opened the physical camera (reset at 11:24:43) before the user
  switched to LensBarSpike.

Implications for the product:
- No evidence Zoom opens the physical camera in the background when the virtual one is
  selected (no resets in any virtual-only scenario, incl. Zoom relaunch).
- `isInUseByAnotherApplication` stayed "no" even while Zoom streamed the OBSBOT directly,
  so it is not a usable "someone else has the camera" signal; use KVO on
  activeVideoMinFrameDuration / measured rate instead.
- Users must switch Zoom's camera to LensBar Camera *before* anything previews the physical
  camera, or the physical rate is already lost. Worth a hint in the install UI/README and an
  "actual fps" warning (Phase 1 RateMonitor).
- Zoom opens the source stream many times per call (start/stop on every video toggle and
  device switch; 5–6 sessions in ~2 min) → the grace period in task_574f matters.
