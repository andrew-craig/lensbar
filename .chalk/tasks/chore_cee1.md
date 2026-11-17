---
id: chore_cee1
title: Remove SwiftLint relaxations from .swiftlint.yml and fix the code
type: chore
status: open
priority: 3
labels: [lint]
blocked_by: []
parent: null
remote_task_url: null
created_at: 2026-11-17T03:07:36Z
updated_at: 2026-11-17T03:07:36Z
---
.swiftlint.yml (added 2026-11-17) temporarily disables `trailing_comma` and sets
`identifier_name` min_length to 1, because existing code breaks both widely and the
SwiftLint CI job (norio-nomura/action-swiftlint, --strict, changed files only) passes
anyway, so local SwiftLint 0.65.1 and CI disagreed.

Done when:
- Both relaxations are removed from .swiftlint.yml (keep only `excluded`), so local
  `swiftlint lint --strict` and the CI job run with default rules.
- Short identifiers (w, h, pb, s, f, ...) are renamed and trailing commas removed, in
  Sources/, Tests/, LensBar/ and Package.swift.
- The other strict findings are fixed too (45 repo-wide on 2026-11-17: comma 17,
  line_length 10, statement_position 3, implicit_optional_initialization 3,
  type_body_length 2, opening_brace 2, large_tuple 2, for_where 2, and one each of
  optional_data_string_conversion, function_parameter_count, file_length,
  cyclomatic_complexity).
- Check why the CI action passes on files that fail locally (likely an old bundled
  SwiftLint); pin or upgrade it so CI and local use the same version.
