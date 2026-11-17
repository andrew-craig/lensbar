---
id: task_623a
title: Extension: single mirrored NV12 format, remembered descriptor, client count, placeholder frame
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-2]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T02:39:35Z
---
PLAN.md §4.5/§6 Phase 2. Source advertises one format + one frame rate set by the app; remember last pushed descriptor for when the app isn't running. Client-count custom property from source start/stop. Placeholder frame ('Open LensBar') when no sink data.

## Notes from spike (2026-11-17)
- Format change = provider.removeDevice + addDevice with the same deviceID, only at zero
  clients. Rebuilt streams need fresh stream UUIDs ("streamID already included").
- Client count: custom property 4cc_lbcc_glob_0000 (String) + device.notifyPropertiesChanged
  on each source start/stop; works (task_9413). Reference: spike/camera-extension/Extension/Provider.swift.

## Result (2026-11-17)
LensBar/LensBarCamera/CameraDevice.swift. Format policy is VirtualCameraKit.AdvertisedFormatState with a
2 s settle delay at zero clients (Zoom drops to 0 on every video toggle). lbfm writes are persisted via
FormatStore even while deferred; reads return the advertised format. Stale stream callbacks after a
device replacement are ignored by generation. Placeholder rendered once per format with CoreText
(checked as a PNG). Runtime behaviour not yet exercised: needs Phase 3 sink feed + Phase 4 installer.
