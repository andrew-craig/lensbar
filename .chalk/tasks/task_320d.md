---
id: task_320d
title: release.yml: install profiles, per-target specifiers, ExportOptions provisioningProfiles, verify
type: task
status: open
priority: 1
labels: [virtual-camera,phase-5,signing,ci]
blocked_by: [task_8103]
parent: epic_7e74
remote_task_url: null
created_at: 2026-11-17T00:06:39Z
updated_at: 2026-11-17T02:39:35Z
---
PLAN.md §6 Phase 5. Both build jobs (arm64 + universal on macos-26). Add provisioningProfiles map to ExportOptions.plist; check codesign -d --entitlements and spctl before notarizing. Validate on a pre-release tag via workflow_dispatch BEFORE merging user-facing UI (risk table).
