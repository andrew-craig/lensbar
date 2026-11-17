---
id: task_a6ae
title: VirtualCameraSink: find device by UID, start sink stream, enqueue re-stamped frames
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-3]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T04:30:00Z
---
PLAN.md §6 Phase 3. CMIO C API; re-stamp frames on the host clock; drop on queue-full.

## Result (2026-11-17)
Sources/LensBar/VirtualCameraSink.swift + CMIOHardware.swift. Attach/detach on a private serial queue; enqueue
re-stamps on the host clock (CMSampleBufferCreateCopyWithNewTiming), drops on a full queue and releases the
retain when CMSimpleQueueEnqueue fails. Sink stream found by direction. Unit tests cover re-stamping, sink
selection and detached enqueue. Not yet exercised against the real extension (needs Phase 4 activation).
