---
id: task_574f
title: Demand-driven lifecycle: client count drives CapturePipeline with grace period
type: task
status: open
priority: 1
labels: [virtual-camera,phase-3]
blocked_by: [task_a6ae]
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T01:48:14Z
---
PLAN.md §6 Phase 3. Client count > 0 adds the virtualCamera demand; 0 removes it after a short grace period so quick re-triggers don't restart the camera. Uses notifications or polling per spike result.

## Notes from spike (2026-11-17)
Drive this from the 'lbcc' property listener (~40 ms latency); keep only a slow safety poll.
Zoom starts and stops the source on every video toggle and camera switch (~6 sessions in 2 min),
so the grace period is essential. Re-resolve the CMIO device by UID when the device list changes.
