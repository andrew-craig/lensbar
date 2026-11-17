---
id: task_2dae
title: Mirror resolution/FPS changes to the extension (applyFormat / applyFPS)
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-3]
blocked_by: [task_a6ae]
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T04:30:00Z
---
PLAN.md §4.5/§6 Phase 3. Push descriptor on connect and on every format/FPS change. Reconfigure the physical camera first; never enqueue old-format frames after the new descriptor is pushed.

## Revised by spike (2026-11-17)
Per PLAN.md §4.5 (revised): while client count > 0, don't change the advertised format.
Reconfigure the physical camera and keep enqueuing; Zoom follows both size and rate changes.
Push the descriptor to the extension, which applies it (device replace, same deviceID) only
when client count is 0, straight away or deferred. Never removeStream/addStream live
(task_c735: Zoom froze and didn't recover).

## Result (2026-11-17)
CameraViewModel pushes the format (active resolution, NV12, live frame rate) after every session open and
every applyFormat / applyFPS; VirtualCameraMonitor writes lbfm and re-writes when the device object changes
(extension restart or replacement). Frames keep flowing through the unchanged advertised format; the
extension's AdvertisedFormatState decides when to replace the device. Not yet exercised at runtime.
