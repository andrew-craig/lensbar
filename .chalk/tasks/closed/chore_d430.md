---
id: chore_d430
title: Verify universal build (arm64 + x86_64) includes the extension
type: chore
status: closed
priority: 2
labels: [virtual-camera,phase-2]
blocked_by: []
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:38Z
updated_at: 2026-11-17T02:39:35Z
---
PLAN.md §6 Phase 2. Build with ARCHS="arm64 x86_64" -destination generic/platform=macOS and confirm the embedded .systemextension is universal.

## Result (2026-11-17)
`xcodebuild -configuration Release -destination generic/platform=macOS ARCHS="arm64 x86_64"
CODE_SIGNING_ALLOWED=NO build`: app and embedded extension binaries both `x86_64 arm64`.
