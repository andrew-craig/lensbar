---
id: task_a9c6
title: Add LensBarCamera system-extension Xcode target (from Camera Extension template)
type: task
status: closed
priority: 1
labels: [virtual-camera,phase-2]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T02:39:35Z
---
PLAN.md §5/§6 Phase 2. Under LensBar/LensBarCamera/, embedded via Embed System Extensions. Use Xcode's template, don't hand-edit project.pbxproj. Provider, one device 'LensBar Camera' with fixed UID, sink stream forwarding to source stream.

## Result (2026-11-17)
Target `LensBarCamera` under LensBar/LensBarCamera/ (synchronized folder; Info.plist and entitlements
excluded from membership), product com.andrewcraig.LensBar.Camera.systemextension, embedded via an
"Embed System Extensions" copy phase; links VirtualCameraKit. Added to project.pbxproj by hand with the
template's objects because Xcode's template can't be driven headlessly; xcodebuild accepts it.
Also fixed the local package path (`../../lensbar` → `..`).
