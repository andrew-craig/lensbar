---
id: epic_7e74
title: LensBar Camera: virtual camera that pins the physical camera's FPS
type: epic
status: open
priority: 1
labels: [virtual-camera]
blocked_by: []
parent: null
remote_task_url: null
created_at: 2026-11-17T00:05:58Z
updated_at: 2026-11-17T00:05:58Z
---
Implements PLAN.md. Ship a CMIOExtension virtual camera (design A: the app captures and pushes frames into a sink stream) so conferencing apps never open the physical camera and cannot reset its frame rate. Phases 0-6 are child tasks; dependencies are recorded with blocked_by.
