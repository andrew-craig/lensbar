---
id: decision_0e1f
title: Spike go/no-go: record results against exit criteria
type: decision
status: closed
priority: 0
labels: [virtual-camera,phase-0,spike]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T01:37:54Z
---
PLAN.md §6 Phase 0 exit criteria: physical rate holds at 25 fps across every re-trigger scenario with no re-assertion; ~1 frame added latency; activation works from a signed build. Record per-app findings (incl. background-probing apps as known limitations) and the notification-vs-polling answer. Gates Phases 2-5.

## Evidence against exit criteria (prepared 2026-11-17, decision pending)
1. Physical rate holds at 25 fps across every re-trigger scenario with no corrective
   re-assertion: **MET for Zoom** (task_a2c4 run 2: join, video toggle, camera switch,
   leave/rejoin, settings preview, Zoom relaunch — zero changes). Only failure mode seen is
   the user selecting the physical camera directly in Zoom (expected; known limitation).
2. Added latency about one frame: **MET**, ~5 ms enqueue→client (one frame is 40 ms).
3. Activation works from a signed build: **PARTLY MET**, works with Apple Development signing
   and automatic profiles; Developer ID + notarized activation still unproven (Phase 5 risk).
Additional answers:
- Client count: property listener notifications work (~40 ms); no polling needed (task_9413).
- Format/FPS mirroring: live stream or device replacement disrupts Zoom; pushing frames
  at the new size/rate under a fixed advertised format works. Proposed plan change: update the
  advertised descriptor only when client count is 0 (task_c735).
Open product follow-ups: hint to select LensBar Camera before anything previews the physical
camera; isInUseByAnotherApplication is useless for detecting other clients.

## Decision (2026-11-17): GO
The user approved proceeding with Phases 1–5 using the revised format-mirroring design
(PLAN.md §4.5: advertised format fixed while clients stream; device replaced only at
zero clients). Developer ID activation stays open as a Phase 5 risk.
