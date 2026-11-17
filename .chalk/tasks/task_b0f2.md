---
id: task_b0f2
title: Introduce CapturePipeline: decouple session lifetime from popover
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
PLAN.md §4.4/§6 Phase 1. Session must run when popover open OR virtual-camera clients > 0. CapturePipeline with explicit demand sources (popover, virtualCamera) replacing CameraViewModel.start()/stop() being driven by popover visibility. Unit-test the demand state machine.
