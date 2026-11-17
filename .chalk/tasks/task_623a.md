---
id: task_623a
title: Extension: single mirrored NV12 format, remembered descriptor, client count, placeholder frame
type: task
status: open
priority: 1
labels: [virtual-camera,phase-2]
blocked_by: [task_a9c6]
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T00:06:38Z
---
PLAN.md §4.5/§6 Phase 2. Source advertises one format + one frame rate set by the app; remember last pushed descriptor for when the app isn't running. Client-count custom property from source start/stop. Placeholder frame ('Open LensBar') when no sink data.

## Notes from spike (2026-11-17)
- Format change = provider.removeDevice + addDevice with the same deviceID, only at zero
  clients. Rebuilt streams need fresh stream UUIDs ("streamID already included").
- Client count: custom property 4cc_lbcc_glob_0000 (String) + device.notifyPropertiesChanged
  on each source start/stop; works (task_9413). Reference: spike/camera-extension/Extension/Provider.swift.
