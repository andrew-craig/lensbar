---
id: task_c735
title: Spike: change advertised format/FPS mid-stream and confirm clients follow
type: task
status: closed
priority: 2
labels: [virtual-camera,phase-0,spike]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T01:35:48Z
---
PLAN.md §6 Phase 0 step 5 and §4.5. Source stream advertises one format with one frame rate (min==max frame duration, single validFrameDurations entry). Replace it while a client streams; record which clients follow without reselecting the camera. If a client can't, plan to document 'change settings before joining'.

## Result (2026-11-17) — Zoom does NOT follow a mid-stream format replacement; recommend changing PLAN §4.5
Extension property `4cc_lbfm_glob_0000` = "WxH@fps:mode"; log in `build/spike-format.log`.
Zoom in a test meeting, LensBarSpike selected, Statistics → Video open (Zoom sends 640x360 here,
so the sending resolution can't confirm the received size; frame rate can).

| Step | What changed | Zoom |
|---|---|---|
| 1 none | physical 25→30 fps, advertised format stays 720p/25 | followed: stats ~30 fps, video fine |
| 2 none | physical 720p→1080p, advertised stays 720p | normal picture |
| 3 stream | removeStream+addStream with new format, live | first try: Zoom started the new stream in 64 ms (but OBSBOT had dropped off USB). Retry 12:29:49 (1080p/25→720p/30): **frozen last frame; toggling video did not recover** |
| 4 device | provider.removeDevice + addDevice (same deviceID), video off | re-enabling video worked, no reselect |
| 4b device | same, live (720p/30) | **Zoom auto-disabled video**; re-enabling gave live ~30 fps |

Also learned:
- A removed stream ID can't be re-added to the same device ("streamID already included");
  a device left with zero streams vanishes from the CMIO device list.
- Extension replacement (build 2 → 3) while Zoom was in a meeting: Zoom recovered by itself.
- The OBSBOT dropped off USB once at 12:00:41 during rapid harness restarts and had to be
  replugged. Unclear whether that's related; keep an eye on it.

Recommendation for the product (plan change; needs the user's OK):
- While clients are streaming, keep the advertised format and push frames at the new
  resolution/rate (mode "none"). Zoom handles both rate and size changes this way.
- Update the advertised descriptor (device replace) only when the client count is 0, so the
  next client gets the right format. Never replace streams live.
- Caveat: only Zoom was tested. Other clients might reject frames that don't match the
  advertised format, and that's unverified.
