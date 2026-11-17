---
id: task_ca9d
title: Spike: swiftc harness that holds 25 fps and logs measured frame interval
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-0,spike]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T00:15:19Z
---
PLAN.md §6 Phase 0 step 1. Standalone swiftc harness (see run-app skill) with AVCaptureSession + AVCaptureVideoDataOutput, pins 25 fps, logs the real frame interval from presentation timestamps. Becomes the oracle for every later check. Throwaway code.

## Result (2026-11-17)
`spike/harness/main.swift` → `swiftc -O -o build/spike-harness spike/harness/main.swift`.
Logs measured fps (from PTS), max inter-frame gap, the frame-duration property and
isInUseByAnotherApplication once per second; KVO-logs external changes; never re-asserts.
Self-test (`spike/harness/selftest.sh`) on OBSBOT Meet SE 1280x720 420v: 25.00 fps at
--fps 25, 30.00 at --fps 30 (first second after start is a warm-up artefact).
Gotcha: camera TCC is per responsible process. The Claude Bash tool is not authorized;
run the harness from the Claude terminal panel (authorized 2026-11-17) or Terminal.app.
