---
id: task_a97d
title: Add FrameTap (AVCaptureVideoDataOutput, NV12 IOSurface) and re-assert FPS after attach
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-1]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T01:48:14Z
---
PLAN.md §5/§6 Phase 1. Attaching a data output is another reconfiguration point that drops activeVideoMinFrameDuration (like startRunning and preview attach in AVFoundationController.openSession), so re-assert FPS after it is attached.
