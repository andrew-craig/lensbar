---
id: task_70ff
title: Filter LensBar's own virtual camera out of enumerateCameras()
type: task
status: open
priority: 1
labels: [virtual-camera,phase-1]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T00:06:38Z
---
PLAN.md §4.4. enumerateCameras() uses .externalUnknown and will list 'LensBar Camera', so LensBar could capture itself. Filter by the fixed device UID (shared constant, later in VirtualCameraKit). Unit-test the filter.
