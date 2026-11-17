---
id: task_29fb
title: Add RateMonitor and show actual fps in the popover
type: task
status: open
priority: 2
labels: [virtual-camera,phase-1]
blocked_by: [task_a97d]
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T00:06:38Z
---
PLAN.md §6 Phase 1. Estimate real frame rate from FrameTap presentation timestamps; display 'actual fps' in ContentView. Report only, never correct (watchdog is out of scope). Rate estimator lives in testable code (moves to VirtualCameraKit in Phase 2) with unit tests.

## Notes from spike (2026-11-17)
AVCaptureDevice.isInUseByAnotherApplication stayed false while Zoom streamed the camera
directly, so it can't flag "someone else reset it". Use measured rate + KVO on
activeVideoMinFrameDuration. Reference implementation: spike/harness/main.swift (FrameCounter).
